// Hibi Cafe POS - Daily Report Email
// Supabase Edge Function
//
// This function receives the daily report from the Hibi POS
// and sends it through Resend.
//
// IMPORTANT:
// RESEND_API_KEY must be configured as a Supabase secret.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "jsr:@supabase/server@^1";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");

const RECIPIENT = "djohargamboa@gmail.com";

// For initial testing, Resend's development sender can be used.
// Later, once you verify your own domain in Resend,
// replace this with your own Hibi Cafe email address.
const SENDER = "Hibi Cafe Daily Reports <onboarding@resend.dev>";

function peso(value: number | string | null | undefined): string {
  const n = Number(value || 0);
  return "₱" + n.toLocaleString("en-PH", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });
}

function esc(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function formatDate(value: unknown): string {
  if (!value) return "";

  const d = new Date(String(value) + "T00:00:00");

  if (Number.isNaN(d.getTime())) {
    return String(value);
  }

  return d.toLocaleDateString("en-PH", {
    year: "numeric",
    month: "long",
    day: "numeric"
  });
}

function buildReportHtml(report: any): string {

  const date = formatDate(report.date);
  const period = report.period || date;

  const totalSales = Number(report.totalSales || 0);
  const transactions = Number(report.transactions || 0);
  const cups = Number(report.cups || 0);
  const foodItems = Number(report.foodItems || 0);

  const cashSales = Number(report.cashSales || 0);
  const gcashSales = Number(report.gcashSales || 0);
  const grabFoodSales = Number(report.grabFoodSales || 0);

  const expenses = Number(report.expenses || 0);
  const netSales = Number(report.netSales || 0);

  const openingCash = Number(report.openingCash || 0);
  const actualCash = Number(report.actualCash || 0);
  const expectedCash = Number(report.expectedCash || 0);
  const variance = Number(report.variance || 0);
  const cashIn = Number(report.cashIn || 0);
  const cashOut = Number(report.cashOut || 0);
  const varianceReason = String(report.varianceReason || "").trim();
  const actualFunds = report.actualFunds || null;

  const varianceLabel =
    Math.abs(variance) < 0.005
      ? "BALANCED"
      : variance > 0
        ? "OVER"
        : "SHORT";

  // ---------------------------------------------------------
  // Payment Breakdown
  // ---------------------------------------------------------

  const paymentRows = (report.paymentBreakdown || [])
    .map((p: any) => `
      <tr>
        <td>${esc(p.method)}</td>
        <td style="text-align:center">${Number(p.transactions || 0)}</td>
        <td style="text-align:right">${peso(p.sales)}</td>
      </tr>
    `)
    .join("");

  // ---------------------------------------------------------
  // Expense Breakdown
  // Cashier is intentionally FIRST.
  // ---------------------------------------------------------

  const expenseRows = (report.expenseRows || [])
    .map((e: any) => `
      <tr>
        <td>${esc(e.cashier || "")}</td>
        <td>${esc(e.date || "")}</td>
        <td>${esc(e.time || "")}</td>
        <td>${esc(e.note || "")}</td>
        <td style="text-align:right">${peso(e.amount)}</td>
      </tr>
    `)
    .join("");


  return `
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">

<style>

body {
  margin: 0;
  padding: 0;
  background: #f5f5f5;
  font-family: Arial, Helvetica, sans-serif;
  color: #222;
}

.container {
  max-width: 800px;
  margin: 0 auto;
  background: #ffffff;
}

.header {
  background: #6F4E37;
  color: white;
  padding: 28px 30px;
}

.header h1 {
  margin: 0 0 6px 0;
  font-size: 24px;
}

.header p {
  margin: 0;
  opacity: .9;
}

.content {
  padding: 28px 30px;
}

.section {
  margin-bottom: 30px;
}

.section-title {
  font-size: 17px;
  font-weight: bold;
  margin-bottom: 12px;
  color: #6F4E37;
}

.summary-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 10px;
}

.summary-card {
  border: 1px solid #e5e5e5;
  border-radius: 8px;
  padding: 14px;
  background: #fafafa;
}

.summary-label {
  font-size: 12px;
  color: #777;
  margin-bottom: 5px;
}

.summary-value {
  font-size: 18px;
  font-weight: bold;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}

th {
  background: #f0f0f0;
  text-align: left;
  padding: 9px;
  border-bottom: 1px solid #ddd;
}

td {
  padding: 9px;
  border-bottom: 1px solid #eee;
}

.total-row td {
  font-weight: bold;
  background: #fafafa;
}

.reconciliation {
  border: 1px solid #ddd;
  border-radius: 8px;
  overflow: hidden;
}

.reconciliation-row {
  display: table;
  width: 100%;
  table-layout: fixed;
  padding: 12px 16px;
  border-bottom: 1px solid #eee;
  box-sizing: border-box;
}

.reconciliation-row > span,
.reconciliation-row > strong {
  display: table-cell;
  vertical-align: top;
}

.reconciliation-row > span {
  width: 62%;
  text-align: left;
  padding-right: 24px;
}

.reconciliation-row > strong {
  width: 38%;
  text-align: right;
  white-space: nowrap;
}

.reconciliation-row:last-child {
  border-bottom: 0;
}

.status {
  font-weight: bold;
}

.footer {
  padding: 20px 30px;
  background: #fafafa;
  color: #777;
  font-size: 12px;
  text-align: center;
}

@media(max-width:600px) {
  .content,
  .header,
  .footer {
    padding-left: 18px;
    padding-right: 18px;
  }

  .summary-grid {
    grid-template-columns: repeat(2, 1fr);
  }

  table {
    font-size: 11px;
  }
}

</style>

</head>

<body>

<div class="container">

  <div class="header">
    <h1>Hibi Cafe</h1>
    <p>Daily Sales & Reconciliation Report</p>
    <p>${esc(date || period)}</p>
  </div>

  <div class="content">

    <!-- SALES SUMMARY -->

    <div class="section">

      <div class="section-title">
        Sales Summary
      </div>

      <div class="summary-grid">

        <div class="summary-card">
          <div class="summary-label">Total Sales</div>
          <div class="summary-value">${peso(totalSales)}</div>
        </div>

        <div class="summary-card">
          <div class="summary-label">Transactions</div>
          <div class="summary-value">${transactions}</div>
        </div>

        <div class="summary-card">
          <div class="summary-label">Cups / Drinks</div>
          <div class="summary-value">${cups}</div>
        </div>

        <div class="summary-card">
          <div class="summary-label">Food Items</div>
          <div class="summary-value">${foodItems}</div>
        </div>

      </div>

    </div>


    <!-- PAYMENT BREAKDOWN -->

    <div class="section">

      <div class="section-title">
        Payment Breakdown
      </div>

      <table>

        <thead>
          <tr>
            <th>Payment Method</th>
            <th style="text-align:center">Transactions</th>
            <th style="text-align:right">Sales</th>
          </tr>
        </thead>

        <tbody>

          ${paymentRows}

          <tr class="total-row">
            <td>TOTAL</td>
            <td style="text-align:center">${transactions}</td>
            <td style="text-align:right">${peso(totalSales)}</td>
          </tr>

        </tbody>

      </table>

      <p style="font-size:12px;color:#777;margin-top:8px;">
        Cash + GCash transactions are split between Cash and GCash
        according to the actual amount received through each method.
      </p>

    </div>


    <!-- SALES CHANNEL -->

    <div class="section">

      <div class="section-title">
        Sales by Channel
      </div>

      <table>

        <thead>
          <tr>
            <th>Channel</th>
            <th style="text-align:right">Sales</th>
          </tr>
        </thead>

        <tbody>

          <tr>
            <td>Walk-in</td>
            <td style="text-align:right">
              ${peso(cashSales + gcashSales)}
            </td>
          </tr>

          <tr>
            <td>GrabFood</td>
            <td style="text-align:right">
              ${peso(grabFoodSales)}
            </td>
          </tr>

          <tr class="total-row">
            <td>Total</td>
            <td style="text-align:right">
              ${peso(totalSales)}
            </td>
          </tr>

        </tbody>

      </table>

    </div>


    <!-- EXPENSES -->

    <div class="section">

      <div class="section-title">
        Expense Breakdown
      </div>

      <table>

        <thead>
          <tr>
            <th>Cashier</th>
            <th>Date</th>
            <th>Time</th>
            <th>Expense</th>
            <th style="text-align:right">Amount</th>
          </tr>
        </thead>

        <tbody>

          ${
            expenseRows ||
            `
            <tr>
              <td colspan="5" style="text-align:center;color:#777">
                No expenses recorded.
              </td>
            </tr>
            `
          }

          <tr><td colspan="5" style="height:10px;padding:0;border:0;background:#fff;"></td></tr>

          <tr class="total-row">
            <td colspan="4">TOTAL EXPENSES</td>
            <td style="text-align:right">
              ${peso(expenses)}
            </td>
          </tr>

        </tbody>

      </table>

    </div>


    <!-- ACTUAL FUNDS -->
    <div class="section">
      <div class="section-title">Actual Funds Balance</div>
      <div class="reconciliation">
        ${actualFunds ? `
        <div class="reconciliation-row"><span>Cash</span><strong>${peso(actualFunds.cash)}</strong></div>
        <div class="reconciliation-row"><span>GCash</span><strong>${peso(actualFunds.gcash)}</strong></div>
        <div class="reconciliation-row"><span>Bank</span><strong>${peso(actualFunds.bank)}</strong></div>
        <div class="reconciliation-row"><span>Snapshot Time</span><strong>${esc(actualFunds.snapshotAt ? new Date(actualFunds.snapshotAt).toLocaleString("en-PH", {timeZone:"Asia/Manila"}) : "")}</strong></div>
        ` : `
        <div class="reconciliation-row"><span>Cash / GCash / Bank</span><strong>Pending reconciliation</strong></div>
        `}
      </div>
    </div>

    <!-- CASH RECONCILIATION -->

    <div class="section">

      <div class="section-title">
        Cash Reconciliation
      </div>

      <div class="reconciliation">

        <div class="reconciliation-row">
          <span>Opening Cash</span>
          <strong>${peso(openingCash)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Cash Sales</span>
          <strong>${peso(cashSales)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>GCash Sales</span>
          <strong>${peso(gcashSales)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Cash In</span>
          <strong>+${peso(cashIn)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Cash Out</span>
          <strong>−${peso(cashOut)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Less: Expenses</span>
          <strong>−${peso(expenses)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Expected Cash</span>
          <strong>${peso(expectedCash)}</strong>
        </div>

        <div class="reconciliation-row">
          <span>Actual Cash</span>
          <strong>${peso(actualCash)}</strong>
        </div>

        <div class="reconciliation-row">

          <span>Variance</span>

          <strong class="status">
            ${Math.abs(variance) < 0.005 ? peso(0) : peso(Math.abs(variance))}
            ${Math.abs(variance) < 0.005 ? " — BALANCED" : " — " + varianceLabel}
          </strong>

        </div>

        ${Math.abs(variance) >= 0.005 && varianceReason ? `
        <div class="reconciliation-row">
          <span>Variance Reason</span>
          <strong style="max-width:65%;text-align:right;">${esc(varianceReason)}</strong>
        </div>` : ""}

      </div>

    </div>


  </div>

  <div class="footer">
    Hibi Cafe POS — Automatically generated daily report
  </div>

</div>

</body>
</html>
`;
}


export default {
  fetch: withSupabase(
    { auth: "none" },

    async (req, _ctx) => {

      try {

        // ---------------------------------------------------
        // Authenticate POS request
        //
        // Preferred: the logged-in Supabase user's access token.
        // Legacy/direct testing: POS_EMAIL_SECRET is still accepted.
        //
        // IMPORTANT: POS_EMAIL_SECRET is never placed in index.html.
        // ---------------------------------------------------

        const posSecret = Deno.env.get("POS_EMAIL_SECRET");
        const providedSecret = req.headers.get("x-pos-email-secret");
        const authHeader = req.headers.get("authorization") || "";

        let authenticated = false;

        // Keep the existing secret-based path working for direct tests.
        if (posSecret && providedSecret === posSecret) {
          authenticated = true;
        }

        // Production POS path: validate the logged-in Supabase session.
        if (!authenticated && authHeader.toLowerCase().startsWith("bearer ")) {
          try {
            const userResponse = await fetch(
              `${Deno.env.get("SUPABASE_URL") || "https://ysdnxwvkqyqojrelhcbu.supabase.co"}/auth/v1/user`,
              {
                method: "GET",
                headers: {
                  "apikey": Deno.env.get("SUPABASE_ANON_KEY") || "",
                  "Authorization": authHeader
                }
              }
            );

            authenticated = userResponse.ok;
          } catch (authError) {
            console.error("Supabase user authentication failed:", authError);
          }
        }

        if (!authenticated) {
          return new Response(
            JSON.stringify({
              error: "Invalid credentials"
            }),
            {
              status: 401,
              headers: {
                "Content-Type": "application/json"
              }
            }
          );
        }
        
        // ---------------------------------------------------
        // Check API key
        // ---------------------------------------------------

        if (!RESEND_API_KEY) {

          console.error("RESEND_API_KEY is not configured.");

          return new Response(
            JSON.stringify({
              error: "RESEND_API_KEY is not configured in Supabase."
            }),
            {
              status: 500,
              headers: {
                "Content-Type": "application/json"
              }
            }
          );

        }


        // ---------------------------------------------------
        // Only allow POST
        // ---------------------------------------------------

        if (req.method !== "POST") {

          return new Response(
            JSON.stringify({
              error: "Method not allowed"
            }),
            {
              status: 405,
              headers: {
                "Content-Type": "application/json"
              }
            }
          );

        }


        // ---------------------------------------------------
        // Read report and Excel attachment sent by Hibi POS
        // ---------------------------------------------------

        const requestData = await req.json();

        const report = requestData.report;
        const attachment = requestData.attachment;


        // ---------------------------------------------------
        // Build email
        // ---------------------------------------------------

        const html = buildReportHtml(report);

        const subject =
          `Hibi Cafe Daily Report - ${report.date || "Report"}`;


        // ---------------------------------------------------
        // Send through Resend
        // ---------------------------------------------------

        const resendResponse = await fetch(
          "https://api.resend.com/emails",
          {
            method: "POST",

            headers: {
              "Content-Type": "application/json",
              "Authorization": `Bearer ${RESEND_API_KEY}`
            },

            body: JSON.stringify({

              from: SENDER,

              to: [RECIPIENT],

              subject,

              html,

              attachments: attachment
                ? [
                    {
                      filename: attachment.filename,
                      content: attachment.content
                    }
                  ]
                : []

            })

          }
        );


        const resendData = await resendResponse.json();


        if (!resendResponse.ok) {

          console.error(
            "Resend error:",
            JSON.stringify(resendData)
          );

          return new Response(
            JSON.stringify({
              error: "Resend failed",
              details: resendData
            }),
            {
              status: 502,
              headers: {
                "Content-Type": "application/json"
              }
            }
          );

        }


        // ---------------------------------------------------
        // Success
        // ---------------------------------------------------

        return new Response(
          JSON.stringify({
            success: true,
            message: "Hibi Cafe daily report sent successfully.",
            resend: resendData
          }),
          {
            status: 200,
            headers: {
              "Content-Type": "application/json"
            }
          }
        );


      } catch (error) {

        console.error("Daily report error:", error);

        return new Response(
          JSON.stringify({
            error: error instanceof Error
              ? error.message
              : String(error)
          }),
          {
            status: 500,
            headers: {
              "Content-Type": "application/json"
            }
          }
        );

      }

    }
  )
};