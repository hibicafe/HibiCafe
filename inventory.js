/* Hibi Cafe Inventory UI — Phase 1. Loaded only on the feature branch. */
(()=>{
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=n=>Number(n||0).toLocaleString('en-PH',{maximumFractionDigits:3});
const consumptionOptions=[['g','Grams (g)','mass'],['ml','Milliliters (ml)','volume'],['pc','Pieces (pc)','count'],['kg','Kilograms (kg) · legacy','mass'],['L','Liters (L) · legacy','volume']];
const purchaseOptions=[['g','Grams (g)','mass',1],['kg','Kilograms (kg)','mass',1000],['ml','Milliliters (ml)','volume',1],['L','Liters (L)','volume',1000],['pc','Pieces (pc)','count',1],['bottle','Bottle','volume',null],['carton','Carton','volume',null],['bag','Bag','mass',null],['pack','Pack','count',null],['tray','Tray','count',null],['box','Box','count',null],['jar','Jar','volume',null],['sachet','Sachet','mass',null],['can','Can','volume',null],['tin','Tin','volume',null],['case','Case','count',null],['bundle','Bundle','count',null]];
const unitFamily=u=>({g:'mass',kg:'mass',ml:'volume',L:'volume',pc:'count',bottle:'volume',carton:'volume',bag:'mass',pack:'count',tray:'count',box:'count',jar:'volume',sachet:'mass',can:'volume',tin:'volume',case:'count',bundle:'count'})[u]||'count';
const unitLabel=u=>({g:'g',kg:'kg',ml:'ml',L:'L',pc:'pc',bottle:'bottle',carton:'carton',bag:'bag',pack:'pack',tray:'tray',box:'box',jar:'jar',sachet:'sachet',can:'can',tin:'tin',case:'case',bundle:'bundle'})[u]||u;
const consumptionUnit=item=>item.consumption_unit||item.base_unit||'g';
const purchaseUnit=item=>item.purchase_unit||item.stock_unit||consumptionUnit(item);
const purchaseFactor=item=>Number(item.purchase_conversion_to_base??item.conversion_to_base??1);
const displayQty=(item,q)=>fmt(q/purchaseFactor(item));
const displayUnit=item=>unitLabel(purchaseUnit(item));
const formatBalance=item=>fmt(item.quantity_on_hand/purchaseFactor(item))+' '+displayUnit(item);
const standardFactor=(purchase,consumption)=>{const p=purchaseOptions.find(x=>x[0]===purchase),c=consumptionOptions.find(x=>x[0]===consumption);if(!p||!c||p[2]!==c[2]||p[3]===null)return null;const base={mass:{g:1,kg:1000},volume:{ml:1,L:1000},count:{pc:1}}[p[2]];return base[purchase]/base[consumption]};
let rows=[],cats=[],filter='all',query='',stockFilter='all';
function root(){return $('inventory-content');}
function inventoryTabBar(active){
 const tabs=[['overview','Overview'],['movement','Movement history'],['counts','Stock count history']];if(isSuperuser())tabs.push(['recipes','Recipes & costing'],['categories','Categories']);
 return '<nav class="inv-tabs" aria-label="Inventory sections">'+tabs.map(([id,label])=>'<button type="button" class="inv-tab '+(active===id?'active':'')+'" data-inv-tab="'+id+'">'+label+'</button>').join('')+'</nav>';
}
function bindInventoryTabs(){root().querySelectorAll('[data-inv-tab]').forEach(b=>b.onclick=()=>{const t=b.dataset.invTab;if(t==='overview')render();if(t==='movement')historyModal();if(t==='counts')stockCountHistoryModal();if(t==='recipes'&&isSuperuser())recipeModal();if(t==='categories'&&isSuperuser())categoryModal()})}
function openInventoryView(content,active='movement'){
 const host=root();if(!host)return;
 const heading=(content.match(/<h3>(.*?)<\/h3>/i)||[])[1]||'Inventory workspace';
 host.innerHTML='<div class="inv-wrap inv-workspace"><div class="inv-workspace-top"><div class="inv-crumb">INVENTORY</div><div class="inv-page-heading">'+heading+'</div></div>'+inventoryTabBar(active)+'<div class="inv-page-content">'+content+'</div></div>';
 bindInventoryTabs();
}
function closeInventoryView(){render()}
function css(){if($('inventory-css'))return;const st=document.createElement('style');st.id='inventory-css';st.textContent=`#page-inventory{background:#fff}.inv-wrap{width:100%;padding:26px 30px;overflow:auto;background:#fff;color:#292929}.inv-head{display:flex;justify-content:space-between;gap:16px;align-items:center;flex-wrap:wrap}.inv-head h1{font-size:26px;margin:0}.inv-sub{color:#777;font-size:13px;margin-top:5px}.inv-stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:22px 0}.inv-stat{border:1px solid #e8e8e4;border-radius:12px;padding:16px}.inv-stat strong{display:block;font-size:24px}.inv-stat span{font-size:12px;color:#777}.inv-tools{display:flex;gap:9px;flex-wrap:wrap;margin:16px 0}.inv-tools input,.inv-tools select{border:1px solid #ddd;border-radius:9px;padding:10px 12px;background:white}.inv-table{width:100%;border-collapse:collapse;font-size:13px}.inv-table th,.inv-table td{text-align:left;padding:13px 10px;border-bottom:1px solid #eee}.inv-table th{color:#777;font-weight:600;background:#fafaf8}.inv-pill{display:inline-block;border-radius:20px;padding:4px 9px;background:#edf6ef;color:#28633a;font-size:11px}.inv-pill.low{background:#fff3df;color:#8a5a11}.inv-empty{padding:35px;text-align:center;color:#888;border:1px dashed #ddd;border-radius:12px}.inv-btn{border:0;border-radius:9px;padding:10px 14px;background:#252525;color:white;font-weight:600;cursor:pointer}.inv-btn.secondary{background:#f1f1ee;color:#333}.inv-btn:disabled{opacity:.5}.inv-modal-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.inv-modal-grid label{font-size:12px;color:#666;display:block;margin-bottom:5px}.inv-modal-grid input,.inv-modal-grid select,.inv-modal-grid textarea{width:100%;box-sizing:border-box;padding:10px;border:1px solid #ddd;border-radius:8px;background:#fff}.inv-modal-grid .wide{grid-column:1/-1}.inv-page-top{display:flex;align-items:center;justify-content:space-between;gap:16px;padding-bottom:18px;margin-bottom:22px;border-bottom:1px solid #e9e9e5}.inv-crumb{font-size:10px;font-weight:800;letter-spacing:1.4px;color:#9a866e}.inv-page-heading{font-size:20px;font-weight:750;margin-top:4px;color:#292929}.inv-page-content{max-width:1500px;margin:0 auto}.inv-page-content .modal-head{margin:0 0 18px;padding:0}.inv-page-content .modal-head h3{font-size:23px;margin:0 0 6px;color:#292929}.inv-page-content .msub{font-size:13px;color:#777;line-height:1.5}.inv-page-content .modal-body{padding:0;margin:0 0 22px;max-height:none;overflow:visible}.inv-page-content .modal-foot{display:flex;justify-content:flex-end;gap:9px;padding:16px 0 0;border-top:1px solid #eee;position:sticky;bottom:0;background:#fff}.inv-page-content .inv-modal-grid{max-width:1050px}.inv-page-content .inv-table{min-width:760px}.inv-page-content .inv-table th{position:sticky;top:0;z-index:1}.inv-page-content .inv-empty{max-width:100%}.inv-page-content input,.inv-page-content select,.inv-page-content textarea{font:inherit}
 .inv-workspace-tools{display:flex;gap:9px;flex-wrap:wrap;align-items:center;margin:0 0 16px;padding:13px;background:#fff;border:1px solid #e6e9e1;border-radius:12px}
 .inv-workspace-tools input,.inv-workspace-tools select{min-height:39px;padding:9px 11px;border:1px solid #dfe3d9;border-radius:8px;background:#fff;min-width:150px}
 .inv-workspace-tools input[type=date]{min-width:145px}.inv-result-count{font-size:11px;color:#858a7f;margin-left:auto}
 .inv-wrap.inv-workspace{max-width:none;width:100%;box-sizing:border-box;padding:24px 30px 40px;background:#F8F9F6;min-height:100%;overflow:visible}
 .inv-workspace-top{margin-bottom:15px}.inv-workspace-top .inv-crumb{font-size:10px;letter-spacing:.12em;font-weight:800;color:#8a907f}.inv-page-heading{font-size:24px;font-weight:750;letter-spacing:-.03em;color:#30372a;margin-top:5px}
 .inv-tabs{display:flex;align-items:center;gap:5px;overflow-x:auto;white-space:nowrap;border-bottom:1px solid #dfe4d9;margin:0 0 20px;padding:0 2px;scrollbar-width:thin}
 .inv-tab{appearance:none;border:0;border-bottom:3px solid transparent;background:transparent;color:#73796c;padding:12px 16px 11px;font:inherit;font-size:12px;font-weight:700;cursor:pointer;margin-bottom:-1px}
 .inv-tab:hover{color:#303a28;background:#f1f4ed}.inv-tab.active{color:#35422b;border-bottom-color:#596b43}
 .inv-page-content{width:100%;max-width:none;min-width:0}.inv-page-content .modal-body{width:100%;max-width:none;box-sizing:border-box}
 .recipe-browser{display:grid;grid-template-columns:minmax(320px,390px) minmax(0,1fr);gap:22px;align-items:start;width:100%;min-width:0}
 .recipe-browser-left,.recipe-browser-right{min-width:0}
 .recipe-product-list{max-height:calc(100vh - 340px);min-height:380px;overflow:auto;padding:10px}
 .recipe-product-card{padding:11px;gap:13px}.recipe-product-thumb{width:58px;height:58px;flex-basis:58px}
 .recipe-product-meta strong{font-size:13px}.recipe-product-meta span{font-size:11px}
 .recipe-detail-head{padding:20px;gap:18px}.recipe-detail-photo{width:116px;height:116px;flex-basis:116px}
 .recipe-detail-head h4{font-size:21px}.recipe-detail-head p{font-size:12px}.recipe-detail-body{padding:22px}
 .recipe-detail-body .recipe-row{grid-template-columns:minmax(220px,1.5fr) minmax(100px,.55fr) minmax(100px,.55fr) minmax(110px,.7fr) 42px!important;gap:12px!important}
 .recipe-detail-body .recipe-row input,.recipe-detail-body .recipe-row select{width:100%;min-width:0;box-sizing:border-box;min-height:42px;padding:9px 10px}
 .recipe-detail-body #recipe-cost-summary>div{padding:20px!important;font-size:13px}
 @media(max-width:1050px){.recipe-browser{grid-template-columns:minmax(270px,320px) minmax(0,1fr);gap:14px}.recipe-detail-body{padding:16px}.recipe-detail-body .recipe-row{grid-template-columns:minmax(150px,1.4fr) minmax(75px,.6fr) minmax(80px,.6fr) 38px!important}}
 @media(max-width:760px){.inv-wrap.inv-workspace{padding:18px 13px 28px}.inv-page-heading{font-size:21px}.inv-tab{padding:11px 12px;font-size:11px}.recipe-browser{grid-template-columns:1fr}.recipe-product-list{max-height:310px;min-height:0;display:grid;grid-template-columns:repeat(2,minmax(0,1fr))}.recipe-detail-head{padding:14px}.recipe-detail-photo{width:76px;height:76px;flex-basis:76px}.recipe-detail-body{padding:14px}.recipe-detail-body .recipe-row{grid-template-columns:minmax(0,1fr) minmax(85px,.45fr) minmax(85px,.45fr) 38px!important;gap:8px!important}}
 @media(max-width:480px){.recipe-product-list{grid-template-columns:1fr}.recipe-detail-body .recipe-row{grid-template-columns:minmax(0,1fr) minmax(0,1fr)!important}.recipe-detail-body .recipe-row>div:first-child,.recipe-detail-body .recipe-row .recipe-line-cost{grid-column:1/-1}.inv-tabs{gap:0}.inv-tab{padding-left:10px;padding-right:10px}}
 .recipe-browser-left,.recipe-browser-right{background:#fff;border:1px solid #e5e8e0;border-radius:13px;overflow:hidden;min-width:0}
 .recipe-browser-head{padding:15px;border-bottom:1px solid #edf0e9}.recipe-browser-head strong{display:block;font-size:13px;color:#30372a}
 .recipe-browser-head input,.recipe-browser-head select{width:100%;margin-top:9px;min-height:39px;padding:9px 11px;border:1px solid #dfe3d9;border-radius:8px;background:#fff}
 .recipe-product-list{max-height:690px;overflow:auto;padding:7px}
 .recipe-product-card{width:100%;display:flex;align-items:center;gap:11px;padding:9px;border:1px solid transparent;border-radius:9px;background:#fff;text-align:left;cursor:pointer}
 .recipe-product-card:hover{background:#f7f9f4}.recipe-product-card.active{background:#f0f4eb;border-color:#cbd6bf}
 .recipe-product-thumb{width:48px;height:48px;flex:0 0 48px;border-radius:8px;object-fit:cover;background:#f2f3ef}
 .recipe-product-thumb.placeholder{display:grid;place-items:center;color:#8a907f;font-size:20px}
 .recipe-product-meta{min-width:0;flex:1}.recipe-product-meta strong{display:block;font-size:12px;color:#333a2e;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .recipe-product-meta span{display:block;font-size:10px;color:#858a7f;margin-top:4px}
 .recipe-detail-head{display:flex;gap:15px;align-items:center;padding:16px;border-bottom:1px solid #edf0e9}
 .recipe-detail-photo{width:92px;height:92px;object-fit:cover;border-radius:11px;background:#f2f3ef;flex:0 0 92px}
 .recipe-detail-head h4{font-size:18px;margin:0 0 5px;color:#30372a}.recipe-detail-head p{font-size:11px;color:#858a7f;margin:0}
 .recipe-detail-body{padding:16px}.recipe-size-tabs{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 16px}
 .recipe-size-tab{border:1px solid #dfe4d9;background:#fff;color:#525b49;border-radius:8px;padding:8px 11px;font-size:11px;font-weight:700;cursor:pointer}
 .recipe-size-tab.active{background:#39452d;color:#fff;border-color:#39452d}.recipe-empty{padding:30px 16px;text-align:center;color:#858a7f;font-size:12px}
 .recipe-detail-body .recipe-row{grid-template-columns:minmax(0,1fr) 95px 82px auto!important}
 @media(max-width:850px){.recipe-browser{grid-template-columns:1fr}.recipe-product-list{max-height:300px;display:grid;grid-template-columns:repeat(2,minmax(0,1fr))}.recipe-detail-head{align-items:flex-start}.recipe-detail-photo{width:72px;height:72px;flex-basis:72px}}
 @media(max-width:560px){.recipe-product-list{grid-template-columns:1fr}.recipe-detail-head{gap:10px}.recipe-detail-photo{width:62px;height:62px;flex-basis:62px}.recipe-detail-head h4{font-size:15px}.recipe-detail-body .recipe-row{grid-template-columns:1fr 1fr!important}}
 .inv-page-content .recipe-row{grid-template-columns:minmax(0,1fr) 100px 100px auto!important}.inv-page-content .recipe-row>div{min-width:0}@media(max-width:700px){.inv-wrap{padding:18px 14px}.inv-stats{grid-template-columns:1fr 1fr}.inv-table{min-width:650px}.inv-modal-grid{grid-template-columns:1fr}.inv-page-top{align-items:flex-start;flex-direction:column}.inv-page-content .modal-foot{position:static}.inv-page-content .inv-table{min-width:760px}.inv-page-content .recipe-row{grid-template-columns:1fr 1fr!important}.inv-page-content .recipe-row .recipe-remove{align-self:end}}`;document.head.appendChild(st)}
async function load(){const [a,b]=await Promise.all([supabaseClient.from('inventory_items').select('id,name,category_id,base_unit,stock_unit,conversion_to_base,consumption_unit,purchase_unit,purchase_conversion_to_base,minimum_stock,purchase_price,active').eq('active',true).order('name'),supabaseClient.from('inventory_categories').select('id,name,sort_order,active').eq('active',true).order('sort_order').order('name')]);if(a.error)throw a.error;if(b.error)throw b.error;cats=b.data||[];const bal=await supabaseClient.from('inventory_balances').select('item_id,quantity_on_hand');if(bal.error)throw bal.error;const map=new Map((bal.data||[]).map(x=>[x.item_id,Number(x.quantity_on_hand)]));rows=(a.data||[]).map(x=>({...x,quantity_on_hand:map.get(x.id)||0}));render()}
function inventoryPolishCss(){
 if($('inventory-polish-css'))return;
 const st=document.createElement('style');st.id='inventory-polish-css';
 st.textContent=`
 #page-inventory{background:#F8F9F6}
 #inventory-content{min-height:100%;background:#F8F9F6}
 .inv-wrap.inv-overview{max-width:1600px;margin:0 auto;padding:28px 30px 40px;background:#F8F9F6;color:#292D25}
 .inv-overview .inv-overview-head{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;flex-wrap:wrap;margin-bottom:22px}
 .inv-overview .inv-title h1{font-family:'IBM Plex Sans',sans-serif;font-size:26px;font-weight:750;letter-spacing:-.035em;margin:0;color:#292D25}
 .inv-overview .inv-title p{font-size:13px;color:#85887F;margin:6px 0 0;line-height:1.5}
 .inv-overview .inv-actions{display:flex;gap:8px;flex-wrap:wrap}
 .inv-overview .inv-btn{border-radius:9px;padding:10px 14px;font-size:12px;font-weight:700;transition:background .15s,border-color .15s,transform .15s}
 .inv-overview .inv-btn:hover{transform:translateY(-1px)}
 .inv-overview .inv-btn:not(.secondary){background:#38422C;color:#fff}
 .inv-overview .inv-btn:not(.secondary):hover{background:#29331F}
 .inv-overview .inv-btn.secondary{background:#fff;color:#4E5545;border:1px solid #DFE3D9}
 .inv-overview .inv-btn.secondary:hover{background:#F1F4EC;border-color:#CCD4C2}
 .inv-overview .inv-stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:0 0 18px}
 .inv-overview .inv-stat{background:#fff;border:1px solid #E3E7DE;border-radius:13px;padding:17px 19px;box-shadow:0 3px 12px rgba(39,48,31,.035);min-width:0}
 .inv-overview .inv-stat strong{display:block;font-size:25px;line-height:1.2;letter-spacing:-.03em;color:#343D26;font-variant-numeric:tabular-nums}
 .inv-overview .inv-stat span{display:block;margin-top:6px;font-size:11px;font-weight:650;letter-spacing:.01em;color:#74796C}
 .inv-overview .inv-stat:nth-child(3) strong{color:#9A6A2B}
 .inv-overview .inv-toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:14px 16px;background:#fff;border:1px solid #E3E7DE;border-radius:13px 13px 0 0}
 .inv-overview .inv-tools{display:flex;align-items:center;gap:9px;flex:1 1 480px;margin:0}
 .inv-overview .inv-search-wrap{position:relative;flex:1 1 260px;min-width:180px}
 .inv-overview .inv-search-wrap input{width:100%;box-sizing:border-box;height:40px;padding:0 13px 0 38px;border:1px solid #E0E3DC;border-radius:9px;background:#FBFCFA;color:#30342C;font:inherit;font-size:13px;outline:none}
 .inv-overview .inv-search-wrap:before{content:'⌕';position:absolute;left:13px;top:7px;color:#828879;font-size:21px;line-height:1}
 .inv-overview .inv-search-wrap input:focus,.inv-overview .inv-tools select:focus{border-color:#8D9A79;box-shadow:0 0 0 3px rgba(119,139,94,.13)}
 .inv-overview .inv-tools select{height:40px;min-width:170px;padding:0 34px 0 12px;border:1px solid #E0E3DC;border-radius:9px;background:#FBFCFA;color:#454A40;font:inherit;font-size:12px}
 .inv-overview .inv-refresh{height:40px}
 .inv-overview .inv-table-panel{background:#fff;border:1px solid #E3E7DE;border-top:0;border-radius:0 0 13px 13px;overflow:hidden;box-shadow:0 3px 12px rgba(39,48,31,.025)}
 .inv-overview .inv-table-heading{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:16px 18px;border-bottom:1px solid #ECEFE9}
 .inv-overview .inv-table-heading strong{font-size:13px;color:#343D26}
 .inv-overview .inv-table-heading span{font-size:11px;color:#858A7F}
 .inv-overview .inv-table-scroll{width:100%;overflow-x:auto}
 .inv-overview .inv-table{width:100%;min-width:920px;border-collapse:separate;border-spacing:0;font-size:12px}
 .inv-overview .inv-table th{position:static;text-align:left;padding:12px 14px;background:#F5F7F2;color:#72796A;font-size:10px;font-weight:800;letter-spacing:.055em;text-transform:uppercase;border-bottom:1px solid #E7EBE2;white-space:nowrap}
 .inv-overview .inv-table td{padding:13px 14px;border-bottom:1px solid #EEF0EB;color:#50554B;vertical-align:middle;white-space:nowrap}
 .inv-overview .inv-table tbody tr:last-child td{border-bottom:0}
 .inv-overview .inv-table tbody tr:hover td{background:#FBFCF9}
 .inv-overview .inv-table .inv-ingredient-name{font-weight:750;color:#30362B}
 .inv-overview .inv-table .inv-muted{color:#92978D}
 .inv-overview .inv-table .inv-price{font-variant-numeric:tabular-nums;color:#555D4C}
 .inv-overview .inv-pill{padding:5px 9px;border-radius:7px;background:#EDF4E9;color:#526B43;font-size:10px;font-weight:750}
 .inv-overview .inv-pill.low{background:#FFF3E2;color:#95611F}
 .inv-overview .inv-row-actions{display:flex;align-items:center;gap:6px}
 .inv-overview .inv-row-actions .inv-btn{padding:7px 10px;font-size:10px;white-space:nowrap}
 .inv-overview .inv-empty{margin:16px;padding:38px 18px;background:#FBFCFA;border:1px dashed #DDE3D7;border-radius:10px;color:#777E70;font-size:12px}
 @media(max-width:760px){
  .inv-wrap.inv-overview{padding:19px 13px 28px}
  .inv-overview .inv-overview-head{margin-bottom:16px}
  .inv-overview .inv-title h1{font-size:23px}
  .inv-overview .inv-actions{width:100%}
  .inv-overview .inv-actions .inv-btn{flex:1 1 auto}
  .inv-overview .inv-stats{grid-template-columns:repeat(3,minmax(0,1fr));gap:7px}
  .inv-overview .inv-stat{padding:13px 10px;border-radius:10px}
  .inv-overview .inv-stat strong{font-size:20px}
  .inv-overview .inv-stat span{font-size:9px;line-height:1.35}
  .inv-overview .inv-toolbar{padding:11px;align-items:stretch}
  .inv-overview .inv-tools{flex-basis:100%;display:grid;grid-template-columns:minmax(0,1fr) auto}
  .inv-overview .inv-search-wrap{grid-column:1/-1}
  .inv-overview .inv-tools select{width:100%;min-width:0}
  .inv-overview .inv-refresh{width:100%}
  .inv-overview .inv-table-heading{padding:14px}
 }
 @media(max-width:390px){.inv-overview .inv-stat strong{font-size:18px}.inv-overview .inv-stat span{font-size:8.5px}}
 `;
 document.head.appendChild(st);
}
function render(){
 css();inventoryPolishCss();const host=root();if(!host)return;
 const normalizedQuery=query.trim().toLocaleLowerCase();
 const shown=rows.filter(x=>(filter==='all'||x.category_id===filter)&&x.name.toLocaleLowerCase().includes(normalizedQuery)&&(stockFilter==='all'||(stockFilter==='low'?x.quantity_on_hand<=Number(x.minimum_stock)*purchaseFactor(x):x.quantity_on_hand>Number(x.minimum_stock)*purchaseFactor(x))));
 const isLow=x=>x.quantity_on_hand<=Number(x.minimum_stock)*purchaseFactor(x);
 const low=rows.filter(isLow).length;
 const above=rows.length-low;
 host.innerHTML='<div class="inv-wrap inv-overview">'+
  '<div class="inv-overview-head"><div class="inv-title"><h1>Inventory</h1><p>Monitor ingredient levels, record deliveries and manage stock activity.</p></div><button class="inv-btn" id="inv-add">+ Add ingredient</button></div>'+inventoryTabBar('overview')+
  '<div class="inv-stats"><div class="inv-stat"><strong>'+rows.length+'</strong><span>ACTIVE INGREDIENTS</span></div><div class="inv-stat"><strong>'+above+'</strong><span>ABOVE MINIMUM STOCK</span></div><div class="inv-stat"><strong>'+low+'</strong><span>AT OR BELOW MINIMUM</span></div></div>'+
  '<div class="inv-toolbar"><div class="inv-tools"><div class="inv-search-wrap"><input id="inv-search" aria-label="Search ingredients" placeholder="Search ingredients…" value="'+esc(query)+'"></div><select id="inv-filter" aria-label="Filter by category"><option value="all">All categories</option>'+cats.map(c=>'<option value="'+c.id+'" '+(filter===c.id?'selected':'')+'>'+esc(c.name)+'</option>').join('')+'</select><select id="inv-stock-filter" aria-label="Filter by stock status"><option value="all">All stock statuses</option><option value="low" '+(stockFilter==='low'?'selected':'')+'>Low stock</option><option value="in" '+(stockFilter==='in'?'selected':'')+'>In stock</option></select><button class="inv-btn secondary inv-refresh" id="inv-refresh">Refresh</button></div></div>'+
  '<section class="inv-table-panel"><div class="inv-table-heading"><strong>Ingredient list</strong><span>Showing '+shown.length+' of '+rows.length+' ingredients</span></div>'+
  (shown.length?'<div class="inv-table-scroll"><table class="inv-table"><thead><tr><th>Ingredient</th><th>Category</th><th>On hand</th><th>Minimum stock</th><th>Purchase price</th><th>Stock status</th><th>Actions</th></tr></thead><tbody>'+
  shown.map(x=>'<tr><td class="inv-ingredient-name">'+esc(x.name)+'</td><td>'+esc(cats.find(c=>c.id===x.category_id)?.name||'—')+'</td><td>'+formatBalance(x)+'</td><td>'+fmt(x.minimum_stock)+' '+unitLabel(purchaseUnit(x))+'</td><td class="inv-price">'+(x.purchase_price!=null?'₱'+Number(x.purchase_price).toLocaleString('en-PH',{minimumFractionDigits:2,maximumFractionDigits:2})+' / '+unitLabel(purchaseUnit(x)):'<span class="inv-muted">Not set</span>')+'</td><td><span class="inv-pill '+(isLow(x)?'low':'')+'">'+(isLow(x)?'Low stock':'In stock')+'</span></td><td><div class="inv-row-actions"><button class="inv-btn secondary" data-move="'+x.id+'">Stock actions</button> '+(isSuperuser()?'<button class="inv-btn secondary" data-edit="'+x.id+'">Edit</button>':'')+'</div></td></tr>').join('')+
  '</tbody></table></div>':(normalizedQuery||filter!=='all'?'<div class="inv-empty">No ingredients match your search or selected category.</div>':'<div class="inv-empty">No ingredients found. Add your first ingredient to begin tracking stock.</div>'))+
  '</section></div>';
 bindInventoryTabs();
 const search=$('inv-search');
 search.oninput=e=>{const value=e.target.value,start=e.target.selectionStart??value.length,end=e.target.selectionEnd??value.length;query=value;render();const next=$('inv-search');next.focus();next.setSelectionRange(start,end)};
 $('inv-filter').onchange=e=>{filter=e.target.value;render()};
 $('inv-stock-filter').onchange=e=>{stockFilter=e.target.value;render()};
 $('inv-refresh').onclick=()=>load().catch(err=>toast(err.message));
 $('inv-add')?.addEventListener('click',()=>itemModal());

 
 
 host.querySelectorAll('[data-move]').forEach(b=>b.onclick=()=>movementModal(rows.find(x=>x.id===b.dataset.move)));
 host.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>itemModal(rows.find(x=>x.id===b.dataset.edit)));
}
async function itemModal(item=null){if(!isSuperuser()){toast('Only superusers can manage ingredients.');return}let canChangeConsumption=!item;if(item){const [history,counts]=await Promise.all([supabaseClient.from('inventory_movements').select('id',{count:'exact',head:true}).eq('item_id',item.id),supabaseClient.from('inventory_stock_counts').select('id',{count:'exact',head:true}).eq('item_id',item.id)]);canChangeConsumption=Number(item.quantity_on_hand||0)===0&&!history.error&&Number(history.count||0)===0&&!counts.error&&Number(counts.count||0)===0}const cUnit=consumptionUnit(item||{}),pUnit=purchaseUnit(item||{}),factor=purchaseFactor(item||{});const cOptions=consumptionOptions.map(u=>'<option value="'+u[0]+'" '+(cUnit===u[0]?'selected':'')+'>'+u[1]+'</option>').join('');openInventoryView('<div class="modal-head"><h3>'+(item?'Edit ingredient':'Add ingredient')+'</h3><div class="msub">Set how you purchase each ingredient and the smaller unit recipes will consume. Stock is always stored in the consumption unit.</div></div><div class="modal-body"><div class="inv-modal-grid"><div class="wide"><label>Ingredient name</label><input id="inv-name" maxlength="100" value="'+esc(item?.name||'')+'" placeholder="e.g. Vanilla syrup"></div><div><label>Category</label><select id="inv-cat">'+cats.map(c=>'<option value="'+c.id+'" '+(item?.category_id===c.id?'selected':'')+'>'+esc(c.name)+'</option>').join('')+'</select></div><div><label>Consumption unit (used by recipes)</label><select id="inv-consumption" '+(canChangeConsumption?'':'disabled')+'>'+cOptions+'</select>'+(item?(canChangeConsumption?'<div class="inv-sub">No stock or movement history exists, so the consumption unit can still be configured.</div>':'<div class="inv-sub">Locked because stock or movement history exists; this protects historical quantities.</div>'):'')+'</div><div><label>Purchase unit (how you buy it)</label><select id="inv-purchase" '+(canChangeConsumption?'':'disabled')+'></select></div><div class="wide"><label id="inv-conversion-label">Contents in consumption units per purchase unit</label><input id="inv-conversion" type="number" min="0.001" step="0.001" value="'+factor+'" placeholder="e.g. 750"><div class="inv-sub" id="inv-conversion-help">Example: 1 bottle contains 750 ml.</div></div><div><label>Minimum stock ('+unitLabel(pUnit)+')</label><input id="inv-min" type="number" min="0" step="0.001" value="'+(item?Number(item.minimum_stock||0):0)+'"></div><div><label>Latest purchase price (₱ per '+unitLabel(pUnit)+')</label><input id="inv-price" type="number" min="0" step="0.01" value="'+(item?.purchase_price??'')+'" placeholder="e.g. 350"></div></div></div><div class="modal-foot"><button class="btn btn-secondary" id="inv-cancel">Cancel</button><button class="btn btn-primary" id="inv-save">Save ingredient</button></div>');$('inv-cancel').onclick=closeInventoryView;const cSel=$('inv-consumption'),pSel=$('inv-purchase'),conv=$('inv-conversion'),convLabel=$('inv-conversion-label'),convHelp=$('inv-conversion-help');const updatePurchase=()=>{const family=unitFamily(cSel.value),prior=pSel.value||pUnit,choices=purchaseOptions.filter(u=>u[2]===family);pSel.innerHTML=choices.map(u=>'<option value="'+u[0]+'">'+u[1]+'</option>').join('');if(choices.some(u=>u[0]===prior))pSel.value=prior;const meta=purchaseOptions.find(u=>u[0]===pSel.value);const auto=standardFactor(pSel.value,cSel.value);convLabel.textContent='1 '+unitLabel(pSel.value)+' contains how many '+unitLabel(cSel.value)+'?';if(auto!==null){conv.value=auto;conv.disabled=true;convHelp.textContent='Automatic unit conversion.'}else{conv.disabled=!canChangeConsumption;if(!item||pSel.value!==pUnit)conv.value='';else conv.value=factor;convHelp.textContent=canChangeConsumption?'Enter the contents of one '+unitLabel(pSel.value)+' in '+unitLabel(cSel.value)+'. Example: 1 bottle = 750 ml.':'Locked because stock or movement history exists; this protects existing balances.'}};cSel.onchange=updatePurchase;pSel.onchange=updatePurchase;updatePurchase();$('inv-save').onclick=async()=>{const name=$('inv-name').value.trim(),category_id=$('inv-cat').value,consumption_unit=cSel.value,purchase_unit=pSel.value,conversion=Number(conv.value),minimum_stock=Number($('inv-min').value);if(!name||!category_id||!Number.isFinite(minimum_stock)||minimum_stock<0||!Number.isFinite(conversion)||conversion<=0){toast('Complete the ingredient details and enter a valid pack conversion.');return}if(unitFamily(purchase_unit)!==unitFamily(consumption_unit)){toast('Purchase and consumption units must measure the same type of quantity.');return}const purchase_price=$('inv-price').value.trim()===''?null:Number($('inv-price').value);if(purchase_price!==null&&(!Number.isFinite(purchase_price)||purchase_price<0)){toast('Enter a valid purchase price.');return}const payload={name,category_id,base_unit:consumption_unit,consumption_unit,purchase_unit,purchase_conversion_to_base:conversion,stock_unit:purchase_unit,conversion_to_base:conversion,minimum_stock,purchase_price,updated_at:new Date().toISOString(),updated_by:CURRENT_USER.id};const res=item?await supabaseClient.from('inventory_items').update(payload).eq('id',item.id):await supabaseClient.from('inventory_items').insert({...payload,created_by:CURRENT_USER.id});if(res.error){toast(res.error.message);return}await writeAudit(item?'inventory_item_updated':'inventory_item_created','inventory_item',item?.id||'','',{name,consumption_unit,purchase_unit,purchase_conversion_to_base:conversion});closeInventoryView();await load();toast('Ingredient saved.')}}
async function categoryModal(){
 if(!isSuperuser())return;
 const categoryCounts=await Promise.all(cats.map(async c=>{
  const r=await supabaseClient.from('inventory_items').select('id',{count:'exact',head:true}).eq('category_id',c.id);
  return {id:c.id,count:r.error?null:Number(r.count||0),error:r.error};
 }));
 const countById=new Map(categoryCounts.map(x=>[x.id,x]));
 openInventoryView('<div class="modal-head"><h3>Inventory categories</h3><div class="msub">Add and rename categories anytime. A category can be deleted only when no ingredients—active or inactive—are assigned to it.</div></div><div class="modal-body"><div class="inv-stat" style="max-width:560px;margin-bottom:18px"><label style="display:block;font-size:12px;color:#666;margin-bottom:7px">New category name</label><div style="display:flex;gap:8px;flex-wrap:wrap"><input id="inv-category-name" maxlength="80" placeholder="e.g. Dairy & milk" style="flex:1;min-width:220px;border:1px solid #ddd;border-radius:9px;padding:11px"><button class="inv-btn" id="inv-category-add">Add category</button></div></div><h4 style="margin:22px 0 10px">Current categories</h4><div style="overflow:auto"><table class="inv-table"><thead><tr><th>Category</th><th>Ingredients</th><th>Actions</th></tr></thead><tbody>'+cats.map(c=>{const info=countById.get(c.id),count=info?.count;return '<tr><td><strong>'+esc(c.name)+'</strong></td><td>'+(count===null||count===undefined?'Count unavailable':count)+'</td><td><button class="inv-btn secondary" data-category-rename="'+c.id+'">Rename</button> <button class="inv-btn secondary" data-category-delete="'+c.id+'" '+(count!==0?'disabled title="Delete is allowed only when no ingredients are assigned"':'')+'>Delete</button>'+(count===null?'<div class="inv-sub">Could not verify ingredient count; deletion is disabled.</div>':count>0?'<div class="inv-sub">Move or remove all '+count+' assigned ingredient'+(count===1?'':'s')+' before deleting.</div>':'')+'</td></tr>'}).join('')+'</tbody></table></div></div>', 'categories');
 $('inv-category-add').onclick=async()=>{const name=$('inv-category-name').value.trim();if(!name){toast('Enter a category name.');return}if(cats.some(c=>c.name.toLowerCase()===name.toLowerCase())){toast('That category already exists.');return}const r=await supabaseClient.from('inventory_categories').insert({name});if(r.error){toast(r.error.message);return}await writeAudit('inventory_category_created','inventory_category','', '',{name});await load();await categoryModal();toast('Category added.')};
 root().querySelectorAll('[data-category-rename]').forEach(btn=>btn.onclick=async()=>{const category=cats.find(c=>c.id===btn.dataset.categoryRename);if(!category)return;const name=window.prompt('Rename category:',category.name);if(name===null)return;const next=name.trim();if(!next){toast('Category name cannot be empty.');return}if(next.toLowerCase()!==category.name.toLowerCase()&&cats.some(c=>c.id!==category.id&&c.name.toLowerCase()===next.toLowerCase())){toast('That category already exists.');return}if(next===category.name)return;const r=await supabaseClient.from('inventory_categories').update({name:next}).eq('id',category.id);if(r.error){toast(r.error.message);return}await writeAudit('inventory_category_renamed','inventory_category',category.id,'',{oldName:category.name,newName:next});await load();await categoryModal();toast('Category renamed.')});
 root().querySelectorAll('[data-category-delete]').forEach(btn=>btn.onclick=async()=>{const category=cats.find(c=>c.id===btn.dataset.categoryDelete);if(!category)return;const check=await supabaseClient.from('inventory_items').select('id',{count:'exact',head:true}).eq('category_id',category.id);if(check.error){toast('Could not verify assigned ingredients. Category was not deleted.');return}const count=Number(check.count||0);if(count>0){toast('Cannot delete: '+count+' ingredient'+(count===1?' is':'s are')+' still assigned to this category.');await categoryModal();return}if(!window.confirm('Delete the empty category "'+category.name+'"? This cannot be undone.'))return;const r=await supabaseClient.from('inventory_categories').delete().eq('id',category.id);if(r.error){toast(r.error.message);return}await writeAudit('inventory_category_deleted','inventory_category',category.id,'',{name:category.name});if(filter===category.id)filter='all';await load();await categoryModal();toast('Category deleted.')});
}
function movementModal(item){
 if(!item)return;
 const cUnit=consumptionUnit(item),pUnit=purchaseUnit(item),factor=purchaseFactor(item);
 openInventoryView('<div class="modal-head"><h3>Record inventory activity</h3><div class="msub">'+esc(item.name)+' · Current stock: '+formatBalance(item)+'</div></div><div class="modal-body"><div class="inv-modal-grid"><div><label>Activity</label><select id="inv-type"><option value="stock_in">Stock delivery</option><option value="stocktake">Physical stock count</option><option value="adjustment">Adjustment</option><option value="waste">Waste / spoilage</option></select></div><div><label id="inv-qty-label">Quantity ('+unitLabel(pUnit)+')</label><input id="inv-qty" type="number" min="0" step="0.001" placeholder="0"></div><div id="inv-direction-wrap" style="display:none"><label>Adjustment direction</label><select id="inv-direction"><option value="add">Add stock</option><option value="subtract">Subtract stock</option></select></div><div class="wide"><label>Reason <span style="color:#b33">*</span></label><input id="inv-reason" maxlength="250" placeholder="Required for counts, adjustments and waste"></div><div class="wide"><label>Supplier / reference (optional)</label><input id="inv-ref" maxlength="120" placeholder="Supplier or delivery reference"></div></div><div class="inv-sub" style="margin-top:12px" id="inv-movement-help">Enter deliveries in '+unitLabel(pUnit)+'. One '+unitLabel(pUnit)+' = '+fmt(factor)+' '+unitLabel(cUnit)+'.</div></div><div class="modal-foot"><button class="btn btn-secondary" id="inv-cancel">Cancel</button><button class="btn btn-primary" id="inv-submit">Save</button></div>');
 $('inv-cancel').onclick=closeInventoryView;
 const updateType=()=>{
  const type=$('inv-type').value,pack=type==='stock_in'||type==='stocktake';
  $('inv-direction-wrap').style.display=type==='adjustment'?'block':'none';
  // Delivery entries track quantity only; purchase expenses are recorded separately in OPEX.
  $('inv-qty-label').textContent=(type==='stocktake'?'Actual physical quantity':type==='stock_in'?'Delivered quantity':'Quantity')+' ('+unitLabel(pack?pUnit:cUnit)+')';
  $('inv-qty').placeholder=type==='stocktake'?fmt(item.quantity_on_hand/factor):'0';
  $('inv-movement-help').textContent=type==='stock_in'?'Enter delivered packages in '+unitLabel(pUnit)+'. Record the delivery cost separately under OPEX.':type==='stocktake'?'Enter the actual quantity on hand in '+unitLabel(pUnit)+'. The POS records the count and automatically adjusts the difference. A reason is required.':'Enter this quantity in '+unitLabel(cUnit)+'. A reason is required.';
 };
 $('inv-type').onchange=updateType;updateType();
 $('inv-submit').onclick=async()=>{
  const type=$('inv-type').value,n=Number($('inv-qty').value),reason=$('inv-reason').value.trim(),reference=$('inv-ref').value.trim();
  if(!Number.isFinite(n)||n<0||(type!=='stocktake'&&n<=0)){toast('Enter a valid quantity.');return}
  if(type!=='stock_in'&&!reason){toast('A reason is required.');return}
  const pack=type==='stock_in'||type==='stocktake',entered_unit=pack?pUnit:cUnit,entered_quantity=n,baseQuantity=pack?n*factor:n;
  if(type==='stocktake'){
   const result=await supabaseClient.rpc('hibi_record_inventory_stock_count',{p_item_id:item.id,p_actual_purchase_quantity:n,p_reason:reason,p_reference:reference||null});
   if(result.error){toast(result.error.message);return}
   const data=Array.isArray(result.data)?result.data[0]:result.data,variance=Number(data?.variance)||0;
   await writeAudit('inventory_stock_count','inventory_item',item.id,reason,{system_quantity:data?.system_quantity,actual_quantity:data?.actual_quantity,variance,purchase_unit:pUnit});
   closeInventoryView();await load();toast(variance===0?'Stock count recorded. No variance.':'Stock count recorded and balance adjusted.');
   return;
  }
  if(type==='stock_in'){
   const r=await supabaseClient.from('inventory_movements').insert({item_id:item.id,movement_type:'stock_in',quantity_delta:Number(baseQuantity.toFixed(3)),entered_quantity:n,entered_unit:pUnit,reason:reason||null,reference:reference||null,created_by:CURRENT_USER.id,created_by_name:currentActor()});
   if(r.error){toast(r.error.message);return}
  }else{
   const delta=type==='waste'||(type==='adjustment'&&$('inv-direction').value==='subtract')?-n:n;
   const r=await supabaseClient.from('inventory_movements').insert({item_id:item.id,movement_type:type,quantity_delta:delta,entered_quantity:n,entered_unit:cUnit,reason,reference:reference||null,created_by:CURRENT_USER.id,created_by_name:currentActor()});
   if(r.error){toast(r.error.message);return}
  }
  await writeAudit('inventory_'+type,'inventory_item',item.id,reason,{entered_quantity:n,entered_unit,quantity_delta:type==='stock_in'?baseQuantity:(type==='waste'||$('inv-direction')?.value==='subtract'?-n:n),reference});
  closeInventoryView();await load();toast('Inventory activity recorded.');
 };
}
async function historyModal(){
 const r=await supabaseClient.from('inventory_movements').select('id,item_id,movement_type,quantity_delta,entered_quantity,entered_unit,reason,reference,supplier,created_at,created_by_name').order('created_at',{ascending:false}).limit(500);
 if(r.error){toast(r.error.message);return}
 const name=id=>rows.find(x=>x.id===id)?.name||'Archived ingredient';
 const qty=x=>{const item=rows.find(i=>i.id===x.item_id),sign=x.quantity_delta<0?'-':'+';if(x.entered_quantity!==null&&x.entered_quantity!==undefined&&x.entered_unit){const entered=sign+fmt(x.entered_quantity)+' '+unitLabel(x.entered_unit);return entered+(x.entered_unit!==consumptionUnit(item||{})?' ('+fmt(Math.abs(x.quantity_delta))+' '+unitLabel(consumptionUnit(item||{}))+')':'')}return sign+fmt(Math.abs(x.quantity_delta))+' '+unitLabel(consumptionUnit(item||{}))};
 const data=r.data||[];
 openInventoryView('<div class="modal-head"><h3>Inventory movement history</h3><div class="msub">Latest 500 stock movements · newest first. Use filters to narrow the ledger.</div></div><div class="inv-workspace-tools"><input type="date" id="move-from" aria-label="From date"><input type="date" id="move-to" aria-label="To date"><select id="move-item"><option value="all">All ingredients</option>'+rows.map(x=>'<option value="'+x.id+'">'+esc(x.name)+'</option>').join('')+'</select><select id="move-type"><option value="all">All movement types</option>'+[...new Set(data.map(x=>x.movement_type))].sort().map(x=>'<option value="'+esc(x)+'">'+esc(x.replace(/_/g,' '))+'</option>').join('')+'</select><input id="move-search" placeholder="Search reason / reference / user" aria-label="Search movement details"><button class="inv-btn secondary" id="move-clear">Clear filters</button><span class="inv-result-count" id="move-count"></span></div><div class="modal-body"><div style="overflow:auto;max-height:none"><table class="inv-table"><thead><tr><th>Date</th><th>Ingredient</th><th>Type</th><th>Quantity</th><th>Reason / Reference</th><th>Recorded by</th></tr></thead><tbody id="move-results"></tbody></table></div></div>');
 const render=()=>{const from=$('move-from').value,to=$('move-to').value,item=$('move-item').value,type=$('move-type').value,q=$('move-search').value.trim().toLowerCase();const shown=data.filter(x=>{const day=new Date(x.created_at).toLocaleDateString('en-CA',{timeZone:'Asia/Manila'});return(!from||day>=from)&&(!to||day<=to)&&(item==='all'||x.item_id===item)&&(type==='all'||x.movement_type===type)&&(!q||[x.reason,x.reference,x.created_by_name,name(x.item_id)].some(v=>String(v||'').toLowerCase().includes(q)))});$('move-count').textContent='Showing '+shown.length+' of '+data.length;$('move-results').innerHTML=shown.map(x=>'<tr><td>'+new Date(x.created_at).toLocaleString('en-PH',{timeZone:'Asia/Manila'})+'</td><td>'+esc(name(x.item_id))+'</td><td>'+esc(x.movement_type.replace(/_/g,' '))+'</td><td>'+qty(x)+'</td><td>'+esc(x.reason||'—')+(x.reference?' · '+esc(x.reference):'')+'</td><td>'+esc(x.created_by_name||'—')+'</td></tr>').join('')||'<tr><td colspan="6" class="inv-empty">No movements match the selected filters.</td></tr>'};
 ['move-from','move-to','move-item','move-type','move-search'].forEach(id=>$(id).addEventListener(id==='move-search'?'input':'change',render));
 $('move-clear').onclick=()=>{['move-from','move-to'].forEach(id=>$(id).value='');$('move-item').value='all';$('move-type').value='all';$('move-search').value='';render()};render();
}
async function stockCountHistoryModal(){
 const r=await supabaseClient.from('inventory_stock_counts').select('id,item_id,system_quantity,actual_quantity,variance,purchase_unit,actual_purchase_quantity,purchase_conversion_to_base,reason,counted_by_name,counted_at').order('counted_at',{ascending:false}).limit(500);
 if(r.error){toast(r.error.message);return}
 const data=r.data||[],name=id=>rows.find(x=>x.id===id)?.name||'Archived ingredient';
 openInventoryView('<div class="modal-head"><h3>Physical stock count history</h3><div class="msub">Latest 500 physical counts · includes counts with no variance.</div></div><div class="inv-workspace-tools"><input type="date" id="count-from" aria-label="From date"><input type="date" id="count-to" aria-label="To date"><select id="count-item"><option value="all">All ingredients</option>'+rows.map(x=>'<option value="'+x.id+'">'+esc(x.name)+'</option>').join('')+'</select><select id="count-variance"><option value="all">All count results</option><option value="variance">With variance</option><option value="matched">No variance</option></select><input id="count-search" placeholder="Search reason / counted by" aria-label="Search count details"><button class="inv-btn secondary" id="count-clear">Clear filters</button><span class="inv-result-count" id="count-result-count"></span></div><div class="modal-body"><div style="overflow:auto;max-height:none"><table class="inv-table"><thead><tr><th>Date</th><th>Ingredient</th><th>System</th><th>Actual</th><th>Variance</th><th>Reason</th><th>Counted by</th></tr></thead><tbody id="count-results"></tbody></table></div></div>', 'counts');
 const render=()=>{const from=$('count-from').value,to=$('count-to').value,item=$('count-item').value,variance=$('count-variance').value,q=$('count-search').value.trim().toLowerCase();const shown=data.filter(x=>{const day=new Date(x.counted_at).toLocaleDateString('en-CA',{timeZone:'Asia/Manila'});return(!from||day>=from)&&(!to||day<=to)&&(item==='all'||x.item_id===item)&&(variance==='all'||(variance==='variance'?Number(x.variance)!==0:Number(x.variance)===0))&&(!q||[x.reason,x.counted_by_name,name(x.item_id)].some(v=>String(v||'').toLowerCase().includes(q)))});$('count-result-count').textContent='Showing '+shown.length+' of '+data.length;$('count-results').innerHTML=shown.map(x=>'<tr><td>'+new Date(x.counted_at).toLocaleString('en-PH',{timeZone:'Asia/Manila'})+'</td><td>'+esc(name(x.item_id))+'</td><td>'+fmt(x.system_quantity/Number(x.purchase_conversion_to_base||1))+' '+esc(x.purchase_unit)+'</td><td>'+fmt(x.actual_purchase_quantity)+' '+esc(x.purchase_unit)+'</td><td>'+fmt(x.variance/Number(x.purchase_conversion_to_base||1))+' '+esc(x.purchase_unit)+'</td><td>'+esc(x.reason||'—')+'</td><td>'+esc(x.counted_by_name||'—')+'</td></tr>').join('')||'<tr><td colspan="7" class="inv-empty">No stock counts match the selected filters.</td></tr>'};
 ['count-from','count-to','count-item','count-variance','count-search'].forEach(id=>$(id).addEventListener(id==='count-search'?'input':'change',render));
 $('count-clear').onclick=()=>{['count-from','count-to'].forEach(id=>$(id).value='');$('count-item').value='all';$('count-variance').value='all';$('count-search').value='';render()};render();
}
function recipeCostingViewCss(){
 if($('recipe-costing-view-css'))return;
 const st=document.createElement('style');st.id='recipe-costing-view-css';
 st.textContent=`
 .recipe-profit-wrap{margin-top:22px;border:1px solid #e1e5dc;border-radius:13px;background:#fff;overflow:hidden}
 .recipe-profit-head{display:flex;align-items:flex-start;justify-content:space-between;gap:14px;flex-wrap:wrap;padding:20px 22px;background:#f5f7f2;border-bottom:1px solid #e6eae2}
 .recipe-profit-head h4{margin:0;color:#30392b;font-size:19px;font-weight:800;letter-spacing:-.025em}
 .recipe-profit-head p{margin:5px 0 0;color:#747b6d;font-size:12px;line-height:1.5}
 .recipe-profit-status{display:inline-flex;align-items:center;border-radius:7px;padding:7px 10px;background:#e8f0e4;color:#4d6840;font-size:10px;font-weight:800;letter-spacing:.04em}
 .recipe-profit-status.incomplete{background:#fff1dc;color:#98621d}
 .recipe-report-section{padding:19px 22px;border-bottom:1px solid #e9ece6}
 .recipe-report-section:last-child{border-bottom:0}
 .recipe-report-title{display:flex;align-items:baseline;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:0 0 12px}
 .recipe-report-title strong{font-size:13px;font-weight:800;color:#343d2d}
 .recipe-report-title span{font-size:11px;color:#818779}
 .recipe-cost-total{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:13px 15px;margin-bottom:13px;background:#f7f9f5;border:1px solid #e7ebe3;border-radius:9px}
 .recipe-cost-total span{font-size:12px;color:#687060;font-weight:700}
 .recipe-cost-total strong{font-size:22px;line-height:1.15;color:#303b29;font-variant-numeric:tabular-nums}
 .recipe-report-table-wrap{width:100%;overflow-x:auto}
 .recipe-report-table{width:100%;border-collapse:collapse;font-size:12px;min-width:570px}
 .recipe-report-table th{padding:10px 12px;background:#f5f7f2;color:#707869;text-align:left;font-size:10px;font-weight:800;letter-spacing:.045em;text-transform:uppercase;border-bottom:1px solid #e5e9e1;white-space:nowrap}
 .recipe-report-table td{padding:11px 12px;border-bottom:1px solid #edf0ea;color:#4c5346;vertical-align:middle}
 .recipe-report-table tbody tr:last-child td{border-bottom:0}
 .recipe-report-table .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
 .recipe-report-table .ingredient{font-weight:750;color:#343b30}
 .recipe-report-table .muted{color:#92988d}
 .recipe-report-table .missing{color:#98621d;font-weight:700}
 .recipe-profit-comparison{width:100%;border-collapse:collapse;min-width:620px;font-size:12px}
 .recipe-profit-comparison th,.recipe-profit-comparison td{padding:12px 14px;border-bottom:1px solid #e9ede6;text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
 .recipe-profit-comparison thead th{background:#f5f7f2;color:#707869;font-size:10px;font-weight:800;letter-spacing:.045em;text-transform:uppercase}
 .recipe-profit-comparison th:first-child,.recipe-profit-comparison td:first-child{text-align:left;white-space:normal}
 .recipe-profit-comparison tbody th{font-weight:650;color:#626a5b}
 .recipe-profit-comparison td{color:#3d4537}
 .recipe-profit-comparison .walk-head{color:#4e6a40}
 .recipe-profit-comparison .grab-head{color:#98652b}
 .recipe-profit-comparison .profit-row th,.recipe-profit-comparison .profit-row td{background:#f7f9f5;font-weight:850;color:#34432d;border-top:1px solid #dfe6d9}
 .recipe-profit-comparison .profit-row td{font-size:17px}
 .recipe-profit-comparison .profit-row td.incomplete-value{font-size:13px;color:#9a6b2b}
 .recipe-profit-foot{padding:13px 22px;background:#fafbf9;color:#7e8578;font-size:10px;line-height:1.6}
 .recipe-profit-missing{margin:14px 22px 18px;padding:12px 14px;border-radius:8px;background:#fff5e7;color:#8b5d20;font-size:11px;line-height:1.55}
 @media(max-width:650px){.recipe-profit-head{padding:16px}.recipe-report-section{padding:15px 13px}.recipe-profit-head h4{font-size:17px}.recipe-cost-total strong{font-size:20px}.recipe-profit-foot{padding:12px 14px}.recipe-profit-missing{margin:12px 13px 15px}}
 `;
 document.head.appendChild(st);
}
async function recipeModal(){
 if(!isSuperuser()){toast('Only superusers can manage recipes.');return}
 const products=Array.isArray(MENU?.products)?MENU.products:[],addons=Array.isArray(ADDONS)?ADDONS:[];
 const targets='<option value="">Choose…</option>'+products.filter(p=>p.active!==false).flatMap(p=>Object.keys(p.sizes||{}).map(s=>'<option value="'+esc(p.id)+'|'+esc(s)+'">'+esc(p.name)+' · '+esc(s)+'</option>')).join('')+addons.filter(a=>a.active!==false).map(a=>'<option value="addon|'+esc(a.id)+'">Add-on · '+esc(a.name)+'</option>').join('');
 openInventoryView('<div class="modal-head"><h3>Recipes &amp; costing</h3><div class="msub">Set ingredient quantities per drink size or add-on. Costs are calculated from each ingredient’s latest purchase price and pack conversion.</div></div><div class="modal-body"><div class="recipe-browser"><aside class="recipe-browser-left"><div class="recipe-browser-head"><strong>Menu products</strong><input id="recipe-product-search" placeholder="Search products…" aria-label="Search products"><select id="recipe-category-filter"><option value="all">All categories</option></select></div><div class="recipe-product-list" id="recipe-product-list"></div></aside><section class="recipe-browser-right"><div class="recipe-detail-head" id="recipe-detail-head"><div class="recipe-empty">Select a product from the list to manage its recipe.</div></div><div class="recipe-detail-body"><div class="recipe-size-tabs" id="recipe-size-tabs"></div><select id="recipe-target" style="display:none" aria-hidden="true">'+targets+'</select><div id="recipe-editor"><div class="recipe-empty">Choose a product or add-on to begin.</div></div><div class="inv-sub" style="margin-top:12px">Walk-in profit = menu price − recipe cost. GrabFood profit = GrabFood price − 25% commission − recipe cost. Ingredient prices come from the latest purchase price and pack conversion.</div></div></section></div><div class="inv-sub" style="margin-top:12px">Walk-in profit = menu price − recipe cost. GrabFood profit = GrabFood price − 25% commission − recipe cost. Enter or update each ingredient’s latest purchase price in its ingredient details. Stock In remains quantity-only; enter actual purchases separately in OPEX.</div></div><div class="modal-foot"><button class="btn btn-primary" id="recipe-save">Save recipe</button></div>', 'recipes');
 const items=rows.filter(x=>x.active);
 const editor=$('recipe-editor'),productList=$('recipe-product-list'),searchBox=$('recipe-product-search'),categoryFilter=$('recipe-category-filter'),sizeTabs=$('recipe-size-tabs'),detailHead=$('recipe-detail-head');
 let selectedBrowserKey='';
 const productCategories=[...new Set(products.filter(p=>p.active!==false).map(p=>p.category||'Uncategorized'))].sort((a,b)=>a.localeCompare(b));
 categoryFilter.innerHTML='<option value="all">All categories</option>'+productCategories.map(c=>'<option value="'+esc(c)+'">'+esc(c)+'</option>').join('');
 const browserEntries=[...products.filter(p=>p.active!==false).map(p=>({key:String(p.id),name:p.name,category:p.category||'Uncategorized',image:p.image||'',kind:'product',item:p})),...addons.filter(a=>a.active!==false).map(a=>({key:'addon|'+a.id,name:a.name,category:'Add-ons',image:'',kind:'addon',item:a}))].sort((a,b)=>a.category.localeCompare(b.category)||a.name.localeCompare(b.name));
 const renderBrowserList=()=>{const q=searchBox.value.trim().toLowerCase(),cat=categoryFilter.value;const visible=browserEntries.filter(x=>(cat==='all'||x.category===cat)&&(!q||x.name.toLowerCase().includes(q)||x.category.toLowerCase().includes(q)));productList.innerHTML=visible.map(x=>'<button type="button" class="recipe-product-card '+(selectedBrowserKey===x.key?'active':'')+'" data-recipe-key="'+esc(x.key)+'">'+(x.image?'<img class="recipe-product-thumb" src="'+esc(x.image)+'" alt="">':'<div class="recipe-product-thumb placeholder">☕</div>')+'<span class="recipe-product-meta"><strong>'+esc(x.name)+'</strong><span>'+esc(x.category)+(x.kind==='addon'?' · Add-on':'')+'</span></span></button>').join('')||'<div class="recipe-empty">No products match your search.</div>';productList.querySelectorAll('[data-recipe-key]').forEach(b=>b.onclick=()=>selectBrowserEntry(b.dataset.recipeKey));};
 const updateDetail=()=>{const v=$('recipe-target').value;if(!v){detailHead.innerHTML='<div class="recipe-empty">Select a product from the list to manage its recipe.</div>';sizeTabs.innerHTML='';return}const addon=v.startsWith('addon|'),parts=v.split('|'),p=addon?addons.find(a=>a.id===parts[1]):products.find(x=>String(x.id)===parts[0]);if(!p)return;detailHead.innerHTML=(p.image?'<img class="recipe-detail-photo" src="'+esc(p.image)+'" alt="">':'<div class="recipe-detail-photo recipe-product-thumb placeholder">☕</div>')+'<div><h4>'+esc(p.name)+'</h4><p>'+esc(addon?'Add-on':'Menu item · '+(p.category||'Uncategorized'))+'</p></div>';if(addon){sizeTabs.innerHTML='<span class="inv-sub">Add-on recipe</span>';return}const sizes=Object.keys(p.sizes||{});sizeTabs.innerHTML=sizes.map(sz=>'<button type="button" class="recipe-size-tab '+(parts.slice(1).join('|')===sz?'active':'')+'" data-recipe-size="'+esc(sz)+'">'+esc(sz)+'</button>').join('');sizeTabs.querySelectorAll('[data-recipe-size]').forEach(b=>b.onclick=()=>{$('recipe-target').value=String(p.id)+'|'+b.dataset.recipeSize;updateDetail();loadTarget();renderBrowserList()});};
 const selectBrowserEntry=key=>{selectedBrowserKey=key;const entry=browserEntries.find(x=>x.key===key);if(!entry)return;if(entry.kind==='addon')$('recipe-target').value=key;else{const first=Object.keys(entry.item.sizes||{})[0];$('recipe-target').value=first?String(entry.item.id)+'|'+first:'';}updateDetail();renderBrowserList();loadTarget();};
 searchBox.oninput=renderBrowserList;categoryFilter.onchange=renderBrowserList;
 renderBrowserList();
 const money=n=>'₱'+Number(n).toLocaleString('en-PH',{minimumFractionDigits:2,maximumFractionDigits:2});
 editor.innerHTML='<div id="recipe-lines"></div><button type="button" class="inv-btn secondary" id="recipe-add-line">+ Add ingredient</button><div id="recipe-cost-summary" style="margin-top:16px"></div>';
 const recipeLinesHost=$('recipe-lines'),summary=$('recipe-cost-summary');
 const ingredientCost=item=>{const price=item?.purchase_price,conversion=Number(item?.purchase_conversion_to_base??item?.purchase_conversion??item?.conversion_to_base);return price!==null&&price!==undefined&&price!==''&&Number.isFinite(Number(price))&&Number(price)>=0&&Number.isFinite(conversion)&&conversion>0?Number(price)/conversion:null};
 const addLine=(id='',qty='',optional=false)=>{const row=document.createElement('div');row.className='inv-modal-grid recipe-row';row.style.cssText='gap:7px;margin:8px 0;align-items:end';row.innerHTML='<div><label>Ingredient</label><select class="recipe-item"><option value="">Choose ingredient…</option>'+items.map(x=>'<option value="'+x.id+'" '+(x.id===id?'selected':'')+'>'+esc(x.name)+' ('+unitLabel(consumptionUnit(x))+')</option>').join('')+'</select></div><div><label>Qty / unit</label><input class="recipe-qty" type="number" min="0.001" step="0.001" value="'+esc(qty)+'"></div><div><label>Optional?</label><select class="recipe-optional"><option value="false" '+(!optional?'selected':'')+'>No</option><option value="true" '+(optional?'selected':'')+'>Yes</option></select></div><div class="recipe-line-cost inv-sub">Cost: —</div><button type="button" class="inv-btn secondary recipe-remove">×</button>';row.querySelector('.recipe-remove').onclick=()=>{row.remove();renderCosting()};row.querySelectorAll('select,input').forEach(el=>el.addEventListener('input',renderCosting));recipeLinesHost.appendChild(row);renderCosting()};
 const selectedTarget=()=>{const v=$('recipe-target').value;if(!v)return null;const parts=v.split('|'),addon=v.startsWith('addon|');if(addon){const a=addons.find(x=>x.id===parts[1]);return a?{addon:true,item:a,name:a.name,walkPrice:Number(a.price)||0,grabPrice:Number(a.grabPrice??a.price)||0}:null}const product=products.find(x=>x.id===parts[0]),size=parts.slice(1).join('|');return product?{addon:false,item:product,name:product.name+' · '+size,walkPrice:Number(product.sizes?.[size])||0,grabPrice:Number(product.grabPrices?.[size]??product.sizes?.[size])||0}:null};
 const renderCosting=()=>{
  let total=0,missing=[],lines=0,ingredientRows=[];
  recipeLinesHost.querySelectorAll('.recipe-row').forEach(row=>{
   const item=items.find(x=>x.id===row.querySelector('.recipe-item')?.value);
   const qty=Number(row.querySelector('.recipe-qty')?.value);
   const unit=ingredientCost(item),out=row.querySelector('.recipe-line-cost');
   if(!item||!Number.isFinite(qty)||qty<=0){out.textContent='Cost: —';return}
   lines++;
   if(unit===null){
    missing.push(item.name);
    ingredientRows.push({name:item.name,qty,unit:consumptionUnit(item),unitCost:null,lineCost:null});
    out.textContent='Cost: price not set';
    return;
   }
   const cost=unit*qty;total+=cost;
   ingredientRows.push({name:item.name,qty,unit:consumptionUnit(item),unitCost:unit,lineCost:cost});
   out.textContent='Cost: '+money(cost)+' ('+money(unit)+' / '+unitLabel(consumptionUnit(item))+')';
  });
  const t=selectedTarget();
  if(!t){summary.innerHTML='<div class="inv-sub">Choose a product to see its recipe cost and projected profit.</div>';return}
  if(!lines){summary.innerHTML='<div class="inv-sub">Add recipe ingredients to calculate cost and profit.</div>';return}
  const incomplete=missing.length>0,walkProfit=t.walkPrice-total,grabCommission=t.grabPrice*.25,grabNet=t.grabPrice-grabCommission,grabProfit=grabNet-total;
  const walkMargin=t.walkPrice>0?walkProfit/t.walkPrice*100:null,grabMargin=grabNet>0?grabProfit/grabNet*100:null;
  const pct=n=>n===null?'—':n.toFixed(1)+'%';
  const amount=n=>incomplete?'—':money(n);
  const ingredientTable='<div class="recipe-report-table-wrap"><table class="recipe-report-table"><thead><tr><th>Ingredient</th><th class="num">Qty / serving</th><th class="num">Cost / unit</th><th class="num">Line cost</th></tr></thead><tbody>'+
   ingredientRows.map(x=>'<tr><td class="ingredient">'+esc(x.name)+'</td><td class="num">'+fmt(x.qty)+' '+esc(unitLabel(x.unit))+'</td><td class="num">'+(x.unitCost===null?'<span class="missing">Price missing</span>':money(x.unitCost)+' / '+esc(unitLabel(x.unit)))+'</td><td class="num">'+(x.lineCost===null?'<span class="missing">—</span>':money(x.lineCost))+'</td></tr>').join('')+
   '</tbody></table></div>';
  const comparison='<div class="recipe-report-table-wrap"><table class="recipe-profit-comparison"><thead><tr><th>Per serving</th><th class="walk-head">Walk-in</th><th class="grab-head">GrabFood</th></tr></thead><tbody>'+
   '<tr><th>Selling / listed price</th><td>'+money(t.walkPrice)+'</td><td>'+money(t.grabPrice)+'</td></tr>'+
   '<tr><th>Platform commission</th><td>—</td><td>− '+money(grabCommission)+'</td></tr>'+
   '<tr><th>Net proceeds</th><td>'+money(t.walkPrice)+'</td><td>'+money(grabNet)+'</td></tr>'+
   '<tr><th>Recipe ingredient cost</th><td>− '+money(total)+'</td><td>− '+money(total)+'</td></tr>'+
   '<tr class="profit-row"><th>Projected profit</th><td class="'+(incomplete?'incomplete-value':'')+'">'+amount(walkProfit)+'</td><td class="'+(incomplete?'incomplete-value':'')+'">'+amount(grabProfit)+'</td></tr>'+
   '<tr><th>Profit margin</th><td>'+(incomplete?'—':pct(walkMargin))+'</td><td>'+(incomplete?'—':pct(grabMargin))+'</td></tr>'+
   '</tbody></table></div>';
  summary.innerHTML='<section class="recipe-profit-wrap" aria-label="Cost and projected profit report">'+
   '<div class="recipe-profit-head"><div><h4>Cost &amp; projected profit</h4><p>'+esc(t.name)+' · Per serving</p></div><span class="recipe-profit-status '+(incomplete?'incomplete':'')+'">'+(incomplete?'COST INCOMPLETE':'COST CALCULATED')+'</span></div>'+
   '<section class="recipe-report-section"><div class="recipe-report-title"><strong>1. Ingredient cost breakdown</strong><span>Latest purchase prices · Per serving</span></div><div class="recipe-cost-total"><span>Total recipe cost</span><strong>'+money(total)+(incomplete?'*':'')+'</strong></div>'+ingredientTable+'</section>'+
   '<section class="recipe-report-section"><div class="recipe-report-title"><strong>2. Selling price &amp; projected profit</strong><span>Side-by-side channel comparison</span></div>'+comparison+'</section>'+
   (incomplete?'<div class="recipe-profit-missing"><strong>Action needed:</strong> Add a latest purchase price for '+missing.map(esc).join(', ')+'. Projected profit is hidden until every recipe ingredient has a valid price. The recipe cost shown is a partial total.</div>':'')+
   '<div class="recipe-profit-foot">Projected profit subtracts ingredient cost only. It does not include packaging, labor, rent, utilities, or other operating expenses. GrabFood profit uses the listed price less a 25% commission.</div></section>';
 };
 const loadTarget=async()=>{recipeLinesHost.innerHTML='';summary.innerHTML='';const v=$('recipe-target').value;if(!v){renderCosting();return}const addon=v.startsWith('addon|'),parts=v.split('|');let q=supabaseClient.from('inventory_recipe_lines').select('item_id,quantity_per_unit,optional').eq('recipe_type',addon?'addon':'product');q=addon?q.eq('addon_id',parts[1]):q.eq('product_id',parts[0]).eq('product_size',parts.slice(1).join('|'));const r=await q;if(r.error){toast(r.error.message);return}(r.data||[]).forEach(x=>addLine(x.item_id,x.quantity_per_unit,x.optional));renderCosting()};
 $('recipe-target').onchange=()=>{updateDetail();loadTarget()};$('recipe-add-line').onclick=()=>addLine();
 $('recipe-save').onclick=async()=>{const target=$('recipe-target').value;if(!target){toast('Choose a product size or add-on.');return}const addon=target.startsWith('addon|'),parts=target.split('|'),payload=[];for(const row of recipeLinesHost.querySelectorAll('.recipe-row')){const item_id=row.querySelector('.recipe-item')?.value;if(!item_id)continue;const qty=Number(row.querySelector('.recipe-qty')?.value);if(!Number.isFinite(qty)||qty<=0){toast('Enter a valid ingredient quantity.');return}payload.push({item_id,quantity_per_unit:qty,optional:row.querySelector('.recipe-optional')?.value==='true'})}if(!payload.length){toast('Add at least one ingredient.');return}const saved=await supabaseClient.rpc('hibi_save_inventory_recipe',{p_recipe_type:addon?'addon':'product',p_product_id:addon?null:parts[0],p_product_size:addon?null:parts.slice(1).join('|'),p_addon_id:addon?parts[1]:null,p_lines:payload});if(saved.error){toast(saved.error.message);return}await writeAudit('inventory_recipe_saved','recipe',target,'',{lines:payload.length});closeInventoryView();await refreshInventoryVariantAvailability();toast('Recipe saved. Costing is calculated from current ingredient purchase prices.')};
 renderCosting();
}
let inventoryRealtime=null;window.renderInventoryPage=()=>{if(!inventoryRealtime&&supabaseClient){inventoryRealtime=supabaseClient.channel('hibi-inventory-live').on('postgres_changes',{event:'*',schema:'public',table:'inventory_balances'},()=>load().catch(console.error)).on('postgres_changes',{event:'*',schema:'public',table:'inventory_items'},()=>load().catch(console.error)).subscribe()}return load().catch(e=>{console.error(e);toast('Could not load inventory: '+e.message)})};
})();