var HQ_GMAIL_CONFIG = Object.freeze({
  endpoint: 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-gmail-ingest',
  source: 'fadewell_apps_script_v1',
  cursorProperty: 'HQ_INTAKE_CURSOR_MS',
  initialLookbackMs: 2 * 24 * 60 * 60 * 1000,
  overlapMs: 60 * 60 * 1000,
  batchSize: 20,
  maxMessagesPerRun: 100,
  maxThreadPages: 5
});

function isTrustedVintedSender_(value) {
  return /(?:^|<)no-reply@vinted\.pl>?\s*$/i.test(String(value || '').trim());
}

function readCandidateMessages_(cutoffMs) {
  var query = 'in:anywhere from:no-reply@vinted.pl after:' + Math.floor(cutoffMs / 1000);
  var byId = {};
  for (var page = 0; page < HQ_GMAIL_CONFIG.maxThreadPages; page += 1) {
    var threads = GmailApp.search(query, page * 100, 100);
    threads.forEach(function (thread) {
      thread.getMessages().forEach(function (message) {
        var receivedMs = message.getDate().getTime();
        var from = message.getFrom();
        if (receivedMs < cutoffMs || !isTrustedVintedSender_(from)) return;
        var id = message.getId();
        byId[id] = {
          gmail_message_id: id,
          gmail_thread_id: message.getThread().getId(),
          sender: from,
          subject: message.getSubject(),
          received_at: message.getDate().toISOString(),
          body: message.getPlainBody()
        };
      });
    });
    if (threads.length < 100) break;
  }
  return Object.keys(byId).map(function (id) { return byId[id]; }).sort(function (a, b) {
    return new Date(a.received_at).getTime() - new Date(b.received_at).getTime();
  }).slice(0, HQ_GMAIL_CONFIG.maxMessagesPerRun);
}

function sendBatch_(messages, observedAt) {
  var identityToken = ScriptApp.getIdentityToken();
  if (!identityToken) {
    throw new Error('Google identity token is unavailable. Save appsscript.json and approve the requested permissions again.');
  }
  var response = UrlFetchApp.fetch(HQ_GMAIL_CONFIG.endpoint, {
    method: 'post',
    contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + identityToken },
    muteHttpExceptions: true,
    payload: JSON.stringify({
      source: HQ_GMAIL_CONFIG.source,
      observed_at: observedAt,
      messages: messages
    })
  });
  var status = response.getResponseCode();
  if (status < 200 || status >= 300) {
    throw new Error('HQ Gmail intake failed (' + status + '): ' + response.getContentText().slice(0, 500));
  }
  return JSON.parse(response.getContentText() || '{}');
}

function syncVintedMail() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return { status: 'already_running', sent: 0 };
  try {
    var properties = PropertiesService.getScriptProperties();
    var startedMs = Date.now();
    var previousCursor = Number(properties.getProperty(HQ_GMAIL_CONFIG.cursorProperty) || 0);
    var cutoffMs = previousCursor
      ? Math.max(0, previousCursor - HQ_GMAIL_CONFIG.overlapMs)
      : startedMs - HQ_GMAIL_CONFIG.initialLookbackMs;
    var messages = readCandidateMessages_(cutoffMs);
    var totals = { scanned: messages.length, sent: 0, received: 0, applied: 0, review: 0, noise: 0 };

    if (!messages.length) {
      sendBatch_([], new Date(startedMs).toISOString());
    } else {
      for (var offset = 0; offset < messages.length; offset += HQ_GMAIL_CONFIG.batchSize) {
        var batch = messages.slice(offset, offset + HQ_GMAIL_CONFIG.batchSize);
        var result = sendBatch_(batch, new Date(startedMs).toISOString());
        totals.sent += batch.length;
        totals.received += Number(result.received || 0);
        totals.applied += Number(result.applied || 0);
        totals.review += Number(result.review || 0);
        totals.noise += Number(result.noise || 0);
      }
    }

    var nextCursor = messages.length >= HQ_GMAIL_CONFIG.maxMessagesPerRun
      ? new Date(messages[messages.length - 1].received_at).getTime()
      : startedMs;
    properties.setProperty(HQ_GMAIL_CONFIG.cursorProperty, String(nextCursor));
    return totals;
  } finally {
    lock.releaseLock();
  }
}

function install() {
  ScriptApp.getProjectTriggers().forEach(function (trigger) {
    if (trigger.getHandlerFunction() === 'syncVintedMail') ScriptApp.deleteTrigger(trigger);
  });
  ScriptApp.newTrigger('syncVintedMail').timeBased().everyMinutes(5).create();
  return syncVintedMail();
}

function resetReplayCursor() {
  PropertiesService.getScriptProperties().deleteProperty(HQ_GMAIL_CONFIG.cursorProperty);
}
