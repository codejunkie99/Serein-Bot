#if DEBUG
import Foundation
import SereinCore

/// Real steps, each labelled by a person as paying, a password, or neither. The label is what the
/// step is, never what the code says about it. `answer` is the door's answer at one standing, with
/// the facts the step's own caller passes. Add a case here when a new way to pay or to enter a
/// password turns up.
enum ApprovalCases {
  enum Label: String { case pay, password, neither }

  enum Step {
    case mac(RelayAutonomy.MacStep)
    /// A page, as HTML. The control the step presses carries `data-serein-target`.
    case page(String)
    /// A `mac_run` command, with "Run commands on this Mac" at its new-install setting.
    case command(String)
    case connector(slug: String, app: String, name: String, description: String)
    /// A Mac script (AppleScript).
    case script(String)
    case plugin(name: String, declared: PluginManifest.Risk?)
  }

  struct Case {
    let id: String
    let label: Label
    let step: Step
  }

  struct Answer: Equatable {
    /// runs, asks, blocked or checks.
    let outcome: String
    /// The effect the door's classifier gives the step.
    let effect: String
  }

  /// The door's answer for the step at `standing`. A page passes its secure-field reading, as the
  /// press does; a connected app's read runs without the door, as `ComposioApps` does.
  static func answer(_ step: Step, _ standing: ApprovalDoor.Standing) -> Answer {
    func door(_ step: ApprovalDoor.Step, _ facts: ApprovalDoor.Facts? = nil) -> Answer {
      let answer = ApprovalDoor.answer(.init(step, standing), facts: facts ?? DoorTable.facts(for: step))
      return Answer(outcome: word(answer), effect: ApprovalDoor.effect(of: step).rawValue)
    }
    switch step {
    case .mac(let step): return door(.macStep(step))
    case .page(let html):
      let reading = PageReading.describe(html: html)
      return door(.effect(ApprovalGate.judge(reading)), DoorTable.facts(secureField: reading.secret || !reading.passwordForm.isEmpty))
    case .command(let command): return door(.command(command, mode: LocalExecution.newInstallDefault))
    case .connector(let slug, let app, let name, let description):
      let kind = ConnectedApps.kind(slug: slug, app: app, name: name, description: description)
      let effect = ConnectedApps.effect(kind, slug: slug, app: app, name: name, description: description)
      return kind == .read ? Answer(outcome: "runs", effect: effect.rawValue) : door(.effect(effect))
    case .script(let source): return door(.script(source))
    case .plugin(let name, let declared): return door(.plugin(name: name, declared: declared))
    }
  }

  static func word(_ answer: ApprovalDoor.Answer) -> String {
    switch answer {
    case .run: return "runs"
    case .card: return "asks"
    case .blocked: return "blocked"
    case .checkFirst: return "checks"
    }
  }

  /// Paying and password steps that run with nobody asked, at `standing`.
  static func running(at standing: ApprovalDoor.Standing) -> Set<String> {
    Set(all.filter { $0.label != .neither && answer($0.step, standing).outcome == "runs" }.map(\.id))
  }

  /// Paying steps the door's classifier rates as another effect: no pay floor meets them.
  static func payNotSeen() -> Set<String> {
    Set(all.filter { $0.label == .pay && answer($0.step, .person(.riskyOnly)).effect != ApprovalGate.Effect.pay.rawValue }.map(\.id))
  }

  /// Paying and password steps that run at Only risky steps and at Allow all, the person there or
  /// not (owner, 2026-11-18: nothing asks at Allow all but the floor). Exact; a case leaves this
  /// list only when the floor meets it.
  static let knownRunning: Set<String> = []

  /// Paying steps no pay floor meets, exact.
  static let knownPayNotSeen: Set<String> = []

  private static func mac(
    _ id: String, _ label: Label, app: String, _ kind: String, role: String? = nil, label text: String? = nil,
    key: String? = nil, typed: String? = nil
  ) -> Case {
    Case(id: id, label: label, step: .mac(RelayAutonomy.MacStep(app: app, kind: kind, role: role, label: text, key: key, text: typed)))
  }
  private static func page(_ id: String, _ label: Label, _ html: String) -> Case {
    Case(id: id, label: label, step: .page(html))
  }
  private static func command(_ id: String, _ label: Label, _ command: String) -> Case {
    Case(id: id, label: label, step: .command(command))
  }
  private static func connector(_ label: Label, _ slug: String, _ name: String, _ description: String = "") -> Case {
    let app = slug.split(separator: "_").first.map { $0.lowercased() } ?? ""
    return Case(id: "connector-" + slug.lowercased(), label: label, step: .connector(slug: slug, app: app, name: name, description: description))
  }
  private static func script(_ id: String, _ label: Label, _ source: String) -> Case {
    Case(id: id, label: label, step: .script(source))
  }
  private static func plugin(_ label: Label, _ name: String, _ declared: PluginManifest.Risk?) -> Case {
    Case(id: "plugin-\(name)-\(declared?.rawValue ?? "unrated")", label: label, step: .plugin(name: name, declared: declared))
  }

  static let all: [Case] = macSteps + pages + commands + connectors + scripts + plugins

  static let macSteps: [Case] = [
    mac("mac-buy", .pay, app: "App Store", "click", role: "AXButton", label: "Buy"),
    mac("mac-pay-now", .pay, app: "Wallet", "click", role: "AXButton", label: "Pay Now"),
    mac("mac-complete-purchase", .pay, app: "Books", "click", role: "AXButton", label: "Complete Purchase"),
    mac("mac-donate", .pay, app: "Safari", "click", role: "AXButton", label: "Donate"),
    mac("mac-checkout", .pay, app: "Shop", "click", role: "AXButton", label: "Checkout"),
    mac("mac-confirm-and-pay", .pay, app: "Uber", "click", role: "AXButton", label: "Confirm and pay"),
    mac("mac-place-order", .pay, app: "Amazon", "click", role: "AXButton", label: "Place your order"),
    mac("mac-subscribe-price", .pay, app: "App Store", "click", role: "AXButton", label: "Subscribe for $9.99 a month"),
    mac("mac-order-now", .pay, app: "DoorDash", "click", role: "AXButton", label: "Order now"),
    mac("mac-bank-transfer", .pay, app: "Chase", "click", role: "AXButton", label: "Transfer"),
    mac("mac-upgrade-plan", .pay, app: "Notion", "click", role: "AXButton", label: "Upgrade to Plus"),
    mac("mac-add-tip", .pay, app: "Uber", "click", role: "AXButton", label: "Add tip"),
    mac("mac-order-history", .neither, app: "Amazon", "click", role: "AXButton", label: "Order history"),
    mac("mac-type-card-number", .pay, app: "Safari", "type", role: "AXTextField", label: "Card number", typed: "4242"),
    mac("mac-return-in-checkout", .pay, app: "Shop", "key", role: "AXButton", label: "Place order", key: "return"),

    mac("mac-secure-field", .password, app: "Safari", "type", role: "AXSecureTextField", label: "Password", typed: "x"),
    mac("mac-system-password-sheet", .password, app: "SecurityAgent", "type", role: "AXSecureTextField", label: "Password", typed: "x"),
    mac("mac-shown-password-field", .password, app: "Safari", "type", role: "AXTextField", label: "Password", typed: "x"),
    mac("mac-passcode-field", .password, app: "Slack", "type", role: "AXTextField", label: "Enter your password", typed: "x"),
    mac("mac-1password", .password, app: "1Password", "click", role: "AXButton", label: "Copy"),
    mac("mac-keychain", .password, app: "Keychain Access", "click", role: "AXButton", label: "Show Password"),
    mac("mac-passwords-app", .password, app: "Passwords", "click", role: "AXButton", label: "Next"),
    mac("mac-sudo-in-terminal", .password, app: "Terminal", "type", role: "AXTextArea", typed: "sudo softwareupdate -i -a"),
    mac("mac-settings-password-pane", .password, app: "System Settings", "click", role: "AXButton", label: "Change Password…"),

    mac("mac-next", .neither, app: "Safari", "click", role: "AXButton", label: "Next"),
    mac("mac-add-event", .neither, app: "Calendar", "click", role: "AXButton", label: "Add Event"),
    mac("mac-type-note", .neither, app: "Notes", "type", role: "AXTextArea", typed: "milk, eggs"),
    mac("mac-type-with-newline", .neither, app: "Notes", "type", role: "AXTextArea", typed: "one\ntwo"),
    mac("mac-scroll", .neither, app: "Music", "scroll"),
    mac("mac-send-mail", .neither, app: "Mail", "click", role: "AXButton", label: "Send"),
    mac("mac-return-in-chat", .neither, app: "Slack", "key", key: "return"),
    mac("mac-move-to-trash", .neither, app: "Finder", "click", role: "AXMenuItem", label: "Move to Trash"),
    mac("mac-command-delete", .neither, app: "Finder", "key", key: "cmd+delete"),
    mac("mac-quit", .neither, app: "Pages", "key", key: "cmd+q"),
    mac("mac-arrow-key", .neither, app: "Keynote", "key", key: "right"),
    mac("mac-ls-in-terminal", .neither, app: "Terminal", "type", role: "AXTextArea", typed: "ls"),
    mac("mac-settings-wifi", .neither, app: "System Settings", "click", role: "AXButton", label: "Wi-Fi"),
    mac("mac-unlabelled-click", .neither, app: "Figma", "click"),
    mac("mac-install", .neither, app: "App Store", "click", role: "AXButton", label: "Install"),
    mac("mac-sign-out", .neither, app: "Music", "click", role: "AXMenuItem", label: "Sign Out"),
  ]

  static let pages: [Case] = [
    page("page-card-form-confirm", .pay, """
      <form action="/checkout"><label>Card number <input name="cardnumber" autocomplete="cc-number"></label>
      <button type="submit" data-serein-target>Confirm</button></form>
      """),
    page("page-price-place-order", .pay, """
      <div><p>Order total: $49.00</p><button data-serein-target>Place order</button></div>
      """),
    page("page-buy-now", .pay, "<main><button data-serein-target>Buy now</button></main>"),
    page("page-euro-continue", .pay, """
      <section><p>Gesamtsumme 49,00 €</p><button data-serein-target>Weiter</button></section>
      """),
    page("page-subscribe-no-price", .pay, "<main><h1>Go Pro</h1><button data-serein-target>Subscribe</button></main>"),
    page("page-one-click-reorder", .pay, "<main><h2>Your usual</h2><button data-serein-target>Reorder</button></main>"),
    page("page-payment-frame-continue", .pay, """
      <main><iframe src="https://js.stripe.com/v3/elements-inner-card.html" title="Secure card payment input frame"></iframe>
      <button data-serein-target>Continue</button></main>
      """),

    page("page-password-field", .password, """
      <form><label>Password <input type="password" name="password" data-serein-target></label></form>
      """),
    page("page-sign-in-button", .password, """
      <form action="/login"><input type="email" name="email"><input type="password" name="password">
      <button type="submit" data-serein-target>Sign in</button></form>
      """),

    page("page-next-link", .neither, #"<main><a href="/page/2" data-serein-target>Next page</a></main>"#),
    page("page-send", .neither, "<form action=\"/messages\"><textarea name=\"body\"></textarea><button data-serein-target>Send</button></form>"),
    page("page-delete", .neither, "<main><button data-serein-target>Delete draft</button></main>"),
    page("page-search", .neither, "<form action=\"/search\"><input name=\"q\"><button type=\"submit\" data-serein-target>Search</button></form>"),
    page("page-accept-cookies", .neither, "<div><p>We use cookies.</p><button data-serein-target>Accept all</button></div>"),
  ]

  static let commands: [Case] = [
    command("command-stripe-charge-curl", .pay, #"curl -s https://api.stripe.com/v1/charges -H "Authorization: Bearer $STRIPE_KEY" -d amount=2000 -d currency=usd"#),
    command("command-stripe-cli-charge", .pay, "stripe charges create --amount 2000 --currency usd"),
    command("command-paypal-payout", .pay, #"curl -s -X POST https://api-m.paypal.com/v1/payments/payouts -d @payout.json"#),
    command("command-buy-domain", .pay, "vercel domains buy example.dev"),
    command("command-crypto-send", .pay, "cast send 0x0000000000000000000000000000000000000001 --value 1ether"),

    command("command-sudo", .password, "sudo softwareupdate -i -a"),
    command("command-sudo-stdin", .password, "echo secret | sudo -S ls /var/root"),
    command("command-read-keychain", .password, "security find-generic-password -s github -w"),
    command("command-su", .password, "su - admin"),
    command("command-passwd", .password, "passwd"),
    command("command-hidden-prompt", .password, #"osascript -e 'display dialog "Password" default answer "" with hidden answer'"#),

    command("command-list", .neither, "ls -la"),
    command("command-git-status", .neither, "git status"),
    command("command-tests", .neither, "npm test"),
    command("command-fetch", .neither, "curl -s https://example.com"),
    command("command-make-folder", .neither, "mkdir -p out"),
    command("command-brew-install", .neither, "brew install jq"),
    command("command-remove", .neither, "rm -rf build"),
    command("command-force-push", .neither, "git push --force"),
    command("command-defaults-write", .neither, "defaults write com.apple.dock autohide -bool true"),
    command("command-overwrite", .neither, "echo hi > notes.txt"),
    command("command-substitution", .neither, "echo $(date)"),
  ]

  static let connectors: [Case] = [
    connector(.pay, "STRIPE_CREATE_CHARGE", "Create charge", "Charge a card or other payment source."),
    connector(.pay, "STRIPE_CREATE_PAYMENT_INTENT", "Create payment intent", "Start collecting a payment from a customer."),
    connector(.pay, "STRIPE_CONFIRM_PAYMENT_INTENT", "Confirm payment intent", "Confirm that the customer intends to pay."),
    connector(.pay, "STRIPE_CAPTURE_PAYMENT_INTENT", "Capture payment intent", "Capture the funds of an authorized payment."),
    connector(.pay, "STRIPE_REFUND_CHARGE", "Refund charge", "Return money to the customer."),
    connector(.pay, "PAYPAL_SEND_PAYOUT", "Send payout", "Send money to one or more recipients."),
    connector(.pay, "WISE_TRANSFER_FUNDS", "Transfer funds", "Move money to a recipient's bank account."),
    connector(.pay, "QUICKBOOKS_PAY_BILL", "Pay bill", "Pay a vendor bill."),
    connector(.pay, "SHOPIFY_CREATE_ORDER", "Create order", "Place an order and charge the saved payment method."),
    connector(.pay, "COINBASE_PLACE_ORDER", "Place order", "Buy or sell a crypto asset."),
    connector(.pay, "SQUARE_CHARGE_CARD", "Charge card", "Charge a card on file."),
    connector(.pay, "GUMROAD_GET_OR_BUY_LICENSE", "Get license", "Returns the license, purchasing one when none exists."),

    connector(.neither, "STRIPE_LIST_CHARGES", "List charges", "Returns the charges on the account."),
    connector(.neither, "GMAIL_SEND_EMAIL", "Send email", "Send an email."),
    connector(.neither, "GMAIL_FETCH_EMAILS", "Fetch emails", "Returns messages that match a query."),
    connector(.neither, "GITHUB_MERGE_PULL_REQUEST", "Merge pull request", "Merge a pull request."),
    connector(.neither, "NOTION_CREATE_PAGE", "Create page", "Create a page in a workspace."),
    connector(.neither, "GOOGLEDRIVE_DELETE_FILE", "Delete file", "Permanently delete a file."),
    connector(.neither, "SLACK_SEARCH_MESSAGES", "Search messages", "Returns messages that match a query."),
  ]

  static let scripts: [Case] = [
    script("script-click-buy", .pay, #"tell application "System Events" to tell process "App Store" to click button "Buy" of window 1"#),
    script("script-click-buy-with-get", .pay, #"tell application "System Events" to tell process "App Store" to click (get button "Buy" of window 1)"#),
    script("script-page-place-order", .pay, #"tell application "Safari" to do JavaScript "document.querySelector('#place-order').click()" in document 1"#),

    script("script-admin-shell", .password, #"do shell script "softwareupdate -i -a" with administrator privileges"#),
    script("script-hidden-prompt", .password, #"display dialog "Enter your password" default answer "" with hidden answer"#),
    script("script-fill-password-sheet", .password, #"tell application "System Events" to tell process "SecurityAgent" to set value of text field 1 of window 1 to "x""#),

    script("script-shell-with-get", .neither, #"get (do shell script "date")"#),
    script("script-read-disks", .neither, #"tell application "Finder" to get name of every disk"#),
    script("script-count-windows", .neither, #"tell application "Finder" to count windows"#),
    script("script-empty-trash", .neither, #"tell application "Finder" to empty trash"#),
    script("script-play", .neither, #"tell application "Music" to play"#),
    script("script-send-mail", .neither, #"tell application "Mail" to send (make new outgoing message with properties {subject:"Hi"})"#),
  ]

  static let plugins: [Case] = [
    plugin(.pay, "pay_invoice", .pay),
    plugin(.pay, "pay_invoice", .write),
    plugin(.pay, "create_invoice_payment", .write),
    plugin(.pay, "charge_card", .read),
    plugin(.pay, "charge_card", nil),
    plugin(.neither, "list_items", .read),
    plugin(.neither, "send_report", .send),
    plugin(.neither, "delete_file", .delete),
  ]
}
#endif
