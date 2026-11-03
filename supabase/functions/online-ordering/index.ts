import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL=Deno.env.get("SUPABASE_URL")!,SERVICE_ROLE_KEY=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin=createClient(SUPABASE_URL,SERVICE_ROLE_KEY,{auth:{persistSession:false}});
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json; charset=utf-8"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
const fail=(message:string,status=400)=>reply({error:message},status);
const clean=(v:unknown,max=160)=>String(v??"").trim().slice(0,max);
const manilaDate=()=>new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Manila",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
const manilaTime=()=>new Intl.DateTimeFormat("en-GB",{timeZone:"Asia/Manila",hour:"2-digit",minute:"2-digit",second:"2-digit",hour12:false}).format(new Date());
async function sha256(value:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));return [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,"0")).join("")}
async function appValue(key:string){const {data,error}=await admin.from("app_data").select("value").eq("key",key).maybeSingle();if(error)throw error;return data?.value??null}
async function getMenuPayload(){
 const [menu,addons,settings,day]=await Promise.all([appValue("hibi-menu"),appValue("hibi-addons"),appValue("hibi-settings"),admin.rpc("hibi_business_day")]);
 if(!menu||!Array.isArray(menu.products))throw new Error("The cafe menu is not available.");
 const businessDate=day.data||manilaDate();
 const {data:availability,error}=await admin.from("product_availability").select("product_id,status,business_date");if(error)throw error;
 const sold=new Set((availability||[]).filter((x:any)=>x.status==="SoldOut").map((x:any)=>String(x.product_id)));
 const products=await Promise.all(menu.products.filter((p:any)=>p&&p.active!==false).map(async(p:any)=>{const sizes=p.sizes&&typeof p.sizes==="object"?p.sizes:{},sizeAvailability:any={};const checks=await Promise.all(Object.keys(sizes).map(async(size)=>{const {data,error}=await admin.rpc("hibi_inventory_variant_availability",{p_product_id:String(p.id),p_size:size,p_addon_ids:[]});if(error)throw error;const row=Array.isArray(data)?data[0]:data;return [size,row?.is_available!==false] as [string,boolean]}));for(const [size,available] of checks)sizeAvailability[size]=available;const allSizes=Object.keys(sizes);return {id:String(p.id),name:String(p.name||""),category:String(p.category||""),image:typeof p.image==="string"?p.image:"",sizes,isDrink:!!(p.isDrink??p.is_drink),sizeAvailability,soldOut:sold.has(String(p.id))||(allSizes.length>0&&allSizes.every(size=>sizeAvailability[size]===false))};}));
 return {businessDate,products,addons:Array.isArray(addons)?addons.filter((a:any)=>a&&a.active!==false).map((a:any)=>({id:String(a.id),name:String(a.name||""),price:Number(a.price)||0})):[],paymentQr:{gcash:typeof settings?.gcashQrUrl==="string"?settings.gcashQrUrl:"",bpi:typeof settings?.bpiQrUrl==="string"?settings.bpiQrUrl:""},cafe:{name:"Hibi Cafe",tagline:"Coffee. Always."}};
}
async function cashier(req:Request){
 const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");if(!token)return {error:"Sign in to the POS first."};
 const {data,error}=await admin.auth.getUser(token);if(error||!data.user)return {error:"Your POS session is invalid. Sign in again."};
 const {data:profile,error:pe}=await admin.from("user_profiles").select("username,display_name,role,active,permissions").eq("auth_user_id",data.user.id).maybeSingle();
 if(pe||!profile||profile.active===false)return {error:"An active POS account is required."};
 const perms=profile.permissions,hasOrders=profile.role==="superuser"||perms?.orders===true||(Array.isArray(perms)&&perms.includes("orders"));
 if(!hasOrders)return {error:"You do not have permission to verify payments."};
 return {userId:data.user.id,name:profile.display_name||profile.username||"POS Staff",role:profile.role};
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});if(req.method!=="POST")return fail("Method not allowed.",405);
 try{
  const body=await req.json(),action=clean(body?.action,30);
  if(action==="menu")return reply(await getMenuPayload());
  if(action==="submit"){
   const name=clean(body?.customer?.name,100),phone=clean(body?.customer?.phone,30),note=clean(body?.customer?.note,300),pickupTime=clean(body?.customer?.pickupTime,5),serviceType=clean(body?.serviceType,20),provider=clean(body?.paymentProvider,20),reference=clean(body?.paymentReference,100),itemsInput=body?.items;
   if(name.length<1)return fail("Enter your name.");
   if(!["Dine In","Take Out"].includes(serviceType))return fail("Choose Dine In or Take Out.");
   if(pickupTime&&!/^([01]\d|2[0-3]):[0-5]\d$/.test(pickupTime))return fail("Enter a valid pickup time.");
   if(pickupTime&&serviceType!=="Take Out")return fail("Pickup time is only available for Take Out orders.");
   if(!["Cash","GCash QR","BPI QR"].includes(provider))return fail("Choose a valid payment method.");
   if(!Array.isArray(itemsInput)||itemsInput.length<1||itemsInput.length>40)return fail("Your cart is empty or too large.");
   
   const catalog=await getMenuPayload();if(provider!=="Cash"&&!(provider==="GCash QR"?catalog.paymentQr.gcash:catalog.paymentQr.bpi))return fail("This QR payment method is not configured yet. Please choose Cash or contact the cafe.");const productById=new Map(catalog.products.map((p:any)=>[String(p.id),p])),addonById=new Map(catalog.addons.map((a:any)=>[String(a.id),a]));
   const items:any[]=[];let subtotal=0;
   for(const raw of itemsInput){
    const product=productById.get(clean(raw?.productId,100)) as any;if(!product||product.soldOut)return fail("One of the items is unavailable. Refresh the menu and try again.");
    const size=clean(raw?.size,80),sizes=product.sizes&&typeof product.sizes==="object"?product.sizes:{};
    if(!Object.prototype.hasOwnProperty.call(sizes,size)||sizes[size]===null||!Number.isFinite(Number(sizes[size])))return fail("A selected size or price is no longer available. Refresh the menu.");
    const qty=Number(raw?.qty);if(!Number.isInteger(qty)||qty<1||qty>20)return fail("Each item quantity must be between 1 and 20.");
    const ids=Array.isArray(raw?.addonIds)?[...new Set(raw.addonIds.map((x:unknown)=>clean(x,100)))]:[];if(ids.length>8)return fail("Too many add-ons selected.");if(ids.length>0&&!(product.isDrink??product.is_drink))return fail("Add-ons are only available for drinks.");
    const chosen=ids.map(id=>{const a=addonById.get(id) as any;if(!a)throw new Error("An add-on is no longer available. Refresh the menu.");const price=Number(a.price);if(!Number.isFinite(price)||price<0)throw new Error("Invalid add-on price.");return{id:String(a.id),name:String(a.name),price}});
    const {data:stockCheck,error:stockError}=await admin.rpc("hibi_inventory_variant_availability",{p_product_id:String(product.id),p_size:size,p_addon_ids:ids});if(stockError)throw stockError;const stockRow=Array.isArray(stockCheck)?stockCheck[0]:stockCheck;if(stockRow?.is_available===false){const names=Array.isArray(stockRow.unavailable_ingredients)?stockRow.unavailable_ingredients.join(", "):"required ingredients";return fail(product.name+" is unavailable because stock is insufficient for: "+names+".");}
    const unitPrice=Number(sizes[size])+chosen.reduce((n,a)=>n+a.price,0),lineTotal=Math.round((unitPrice*qty+Number.EPSILON)*100)/100;subtotal+=lineTotal;
    items.push({productId:String(product.id),name:String(product.name),category:String(product.category||""),size,isDrink:!!(product.isDrink??product.is_drink),qty,unitPrice,lineTotal,addons:chosen});
   }
   subtotal=Math.round((subtotal+Number.EPSILON)*100)/100;const expected=Number(body?.expectedTotal);if(!Number.isFinite(expected)||Math.round((expected+Number.EPSILON)*100)/100!==subtotal)return fail("Menu pricing changed or your cart total is outdated. Refresh the menu and check your order total again.");
   const token=[...crypto.getRandomValues(new Uint8Array(24))].map(x=>x.toString(16).padStart(2,"0")).join("");
   const payload={p_source:"Online",p_service_type:serviceType,p_order_date:catalog.businessDate,p_order_time:manilaTime(),p_created_at:new Date().toISOString(),p_subtotal:subtotal,p_discount_type:null,p_discount_amount:0,p_total:subtotal,p_payment_method:provider==="Cash"?"Cash":"GCash",p_items:items};
   const details={customer_name:name,customer_phone:phone,customer_note:note,pickup_time:pickupTime||null,payment_provider:provider,payment_reference:provider==="Cash"?"":reference.replace(/\D/g,"").slice(-4),tracking_token_hash:await sha256(token)};
   const {data,error}=await admin.rpc("hibi_create_online_order",{p_payload:payload,p_details:details});
   if(error){console.error("online order create failed",error);return fail("We couldn't submit the order. Please refresh and try again.",400)}
   return reply({orderNumber:data.order_code||`HIBI-${String(data.order_number).padStart(4,"0")}`,trackingToken:token,total:Number(data.total),paymentProvider:provider,paymentStatus:"Pending",status:data.status,serviceType:data.service_type,pickupTime:pickupTime||null},201);
  }
  if(action==="track"){
   const rawCode=clean(body?.orderNumber,40).toUpperCase().replace(/^HIBI-?/,"").replace(/\D/g,""),orderNumber=rawCode?"HIBI-"+rawCode.padStart(4,"0"):"",customerName=clean(body?.customerName,100).toLocaleLowerCase().replace(/\s+/g," ");
   if(!/^HIBI-\d{4,}$/.test(orderNumber)||customerName.length<1)return fail("Enter the order code and the customer name used at checkout.");
   let {data:order,error:oe}=await admin.from("pos_orders").select("id,order_number,order_code,order_date,order_time,created_at,total,status,payment_status,service_type").eq("order_code",orderNumber).maybeSingle();
   if(oe)throw oe;
   if(!order){const numeric=Number(rawCode);if(Number.isSafeInteger(numeric)&&numeric>0){const fallback=await admin.from("pos_orders").select("id,order_number,order_code,order_date,order_time,created_at,total,status,payment_status,service_type").eq("order_number",numeric).maybeSingle();if(fallback.error)throw fallback.error;order=fallback.data;}}
   if(!order||String(order.order_code||("HIBI-"+String(order.order_number).padStart(4,"0"))).toUpperCase()!==orderNumber)return fail("We couldn't find that order. Check the code and customer name.",404);
   const {data:detail,error:de}=await admin.from("online_order_details").select("order_id,customer_name,payment_provider,pickup_time").eq("order_id",order.id).maybeSingle();if(de)throw de;
   const normalizeName=(v:unknown)=>String(v??"").trim().toLocaleLowerCase().replace(/\s+/g," ");
   if(!detail||normalizeName(detail.customer_name)!==customerName)return fail("We couldn't find that order. Check the code and customer name.",404);
   const {data:items,error:ie}=await admin.from("pos_order_items").select("name,size,qty,unit_price,line_total,addons").eq("order_id",order.id);if(ie)throw ie;
   return reply({orderNumber:order.order_code||("HIBI-"+String(order.order_number).padStart(4,"0")),total:Number(order.total),status:order.status,paymentStatus:order.payment_status,paymentProvider:detail.payment_provider,serviceType:order.service_type,pickupTime:detail.pickup_time,createdAt:order.created_at,items:(items||[]).map((i:any)=>({name:i.name,size:i.size,qty:i.qty,lineTotal:Number(i.line_total),addons:i.addons||[]}))});
  }
  if(action==="updateOnlineStatus"){
   const auth=await cashier(req);if(auth.error)return fail(auth.error,401);
   const orderId=clean(body?.orderId,60),nextStatus=clean(body?.status,20),reason=clean(body?.reason,300);
   if(!/^[0-9a-f-]{36}$/i.test(orderId))return fail("Invalid order.");
   if(!["Preparing","Completed","Cancelled"].includes(nextStatus))return fail("Invalid online order status.");
   const {data:order,error:oe}=await admin.from("pos_orders").select("id,source,status,payment_status,order_code,order_number,order_date").eq("id",orderId).maybeSingle();
   if(oe)throw oe;if(!order||order.source!=="Online")return fail("Online order not found.",404);const {data:dayData}=await admin.rpc("hibi_business_day");if(auth.role!=="superuser"&&order.order_date!==(dayData||manilaDate()))return fail("Staff can only update online orders for the current business day.");const {data:recon}=await admin.from("eod_reconciliations").select("locked").eq("business_date",order.order_date).maybeSingle();if(auth.role!=="superuser"&&recon?.locked)return fail("This business day is reconciled and locked.");
   if(order.status==="Cancelled")return fail("Cancelled orders cannot be reopened.");
   if(["Preparing","Completed"].includes(nextStatus)&&order.payment_status!=="Paid")return fail("Verify payment before preparing or completing this online order.");
   if(nextStatus==="Cancelled"&&order.payment_status==="Paid")return fail("This order is already paid. Use the POS refund workflow instead of cancelling it.");
   if(nextStatus==="Cancelled"&&reason.trim().length<2)return fail("A cancellation reason is required.");
   if(nextStatus===order.status)return reply({status:order.status,alreadyUpdated:true});
   const patch:any={status:nextStatus,completed_at:nextStatus==="Completed"?new Date().toISOString():null};
   const {data:updated,error:up}=await admin.from("pos_orders").update(patch).eq("id",orderId).select("id,status,payment_status,completed_at").maybeSingle();
   if(up)throw up;if(!updated)return fail("Order status was not updated.");
   return reply({status:updated.status,paymentStatus:updated.payment_status,completedAt:updated.completed_at,orderNumber:order.order_code||`HIBI-${String(order.order_number).padStart(4,"0")}`,updatedBy:auth.name});
  }
  if(action==="cashierDetails"||action==="verifyPayment"){
   const auth=await cashier(req);if(auth.error)return fail(auth.error,401);
   const orderId=clean(body?.orderId,60);if(!/^[0-9a-f-]{36}$/i.test(orderId))return fail("Invalid order.");
   const {data:detail,error:de}=await admin.from("online_order_details").select("order_id,customer_name,customer_phone,customer_note,pickup_time,payment_provider,payment_reference,payment_verified_at,payment_verified_by").eq("order_id",orderId).maybeSingle();if(de)throw de;if(!detail)return fail("Online order details not found.",404);
   if(action==="cashierDetails"){const {data:infoOrder,error:ioe}=await admin.from("pos_orders").select("order_date").eq("id",orderId).maybeSingle();if(ioe)throw ioe;if(!infoOrder)return fail("Order not found.",404);const {data:dayData}=await admin.rpc("hibi_business_day");if(auth.role!=="superuser"&&infoOrder.order_date!==(dayData||manilaDate()))return fail("Staff can only view online customer details for the current business day.");const {data:recon}=await admin.from("eod_reconciliations").select("locked").eq("business_date",infoOrder.order_date).maybeSingle();if(auth.role!=="superuser"&&recon?.locked)return fail("This business day is reconciled and locked.");return reply({customerName:detail.customer_name,customerPhone:detail.customer_phone,customerNote:detail.customer_note,pickupTime:detail.pickup_time,paymentProvider:detail.payment_provider,paymentReference:detail.payment_reference,paymentVerifiedAt:detail.payment_verified_at,paymentVerifiedBy:detail.payment_verified_by});}
   const {data:order,error:oe}=await admin.from("pos_orders").select("id,payment_status,status,order_date,order_code,order_number,total,payment_method").eq("id",orderId).maybeSingle();if(oe)throw oe;if(!order)return fail("Order not found.",404);const {data:dayData}=await admin.rpc("hibi_business_day");if(auth.role!=="superuser"&&order.order_date!==(dayData||manilaDate()))return fail("Staff can only verify payments for the current business day.");const {data:recon}=await admin.from("eod_reconciliations").select("locked").eq("business_date",order.order_date).maybeSingle();if(auth.role!=="superuser"&&recon?.locked)return fail("This business day is reconciled and locked.");if(order.status==="Cancelled")return fail("Cancelled orders cannot be marked paid.");if(order.payment_status==="Paid")return reply({paymentStatus:"Paid",alreadyPaid:true});
   const update:any={payment_status:"Paid"};if(order.payment_method==="Cash"){const received=Number(body?.amountReceived);const total=Number(order.total)||0;if(!Number.isFinite(received)||received<total)return fail("Enter cash received that is at least the order total.");update.amount_received=received;update.change_given=Math.round((received-total+Number.EPSILON)*100)/100;}
   const now=new Date().toISOString();const {error:up}=await admin.from("pos_orders").update(update).eq("id",orderId);if(up)throw up;
   const {error:du}=await admin.from("online_order_details").update({payment_verified_at:now,payment_verified_by:auth.name}).eq("order_id",orderId);if(du)throw du;
   return reply({paymentStatus:"Paid",alreadyPaid:false,verifiedBy:auth.name,verifiedAt:now,orderNumber:order.order_code||`HIBI-${String(order.order_number).padStart(4,"0")}`});
  }
  return fail("Unknown action.",400);
 }catch(error){console.error(error);return fail("Something went wrong. Please try again shortly.",500)}
});
