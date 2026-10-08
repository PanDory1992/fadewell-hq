chrome.action.onClicked.addListener(async tab => {
  let target = 'https://hq.fadewell.eu/capture.html';
  try {
    const source = new URL(tab.url || '');
    if (source.protocol === 'https:' && ['vinted.pl', 'www.vinted.pl'].includes(source.hostname)
      && /^\/items\/\d+(?:-[^/]*)?\/?$/.test(source.pathname)) {
      target += `?url=${encodeURIComponent(source.origin + source.pathname)}`;
    }
  } catch { /* Open the blank HQ capture form. */ }
  await chrome.tabs.create({ url: target });
});
