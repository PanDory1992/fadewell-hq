# FADEWELL source capture for Chrome/Edge

Open `chrome://extensions` or `edge://extensions`, enable Developer mode, choose **Load unpacked**, and select this directory. Pin the extension to the toolbar. Click its icon while viewing a concrete Vinted item. It opens the owner-authenticated HQ capture form with the listing URL filled in. Confirm **Zapisz zdjęcia** before buying.

On iPhone, use the link-sharing instructions on `https://hq.fadewell.eu/capture.html`. The browser extension cannot run inside the Vinted iOS app.

Save while the listing is still open, before paying. HQ links the archive only after the purchase receipt arrives and its title and seller match the saved offer.

The extension requests only `activeTab`. It does not read or export Vinted cookies, purchase history or page contents. It sends only the listing URL to HQ through the opened tab.
