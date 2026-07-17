// Source copy of the external Google Apps Script clock.
// Live project: FADEWELL Vinted Watchdog
// Script ID: 14JtVsaK_pfpoVLgSQKaGJ1L6PPH66FaOx6ep_efz0SdaCO0DQ-whZ7t1
// The live project stores WATCHDOG_SECRET in Script Properties, never here.

const WATCHDOG_URL = 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-vinted-watchdog';

function runWatchdog() {
  const secret = PropertiesService.getScriptProperties().getProperty('WATCHDOG_SECRET');
  if (!secret) throw new Error('WATCHDOG_SECRET is missing');

  const response = UrlFetchApp.fetch(WATCHDOG_URL, {
    method: 'post',
    headers: { Authorization: 'Bearer ' + secret },
    muteHttpExceptions: true,
  });

  const status = response.getResponseCode();
  const body = response.getContentText();
  console.log(JSON.stringify({ status: status, body: body }));

  if (status >= 300) {
    throw new Error('Watchdog HTTP ' + status + ': ' + body);
  }
}
