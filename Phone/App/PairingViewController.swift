import ActivityKit
import UIKit

/// The app's only screen: pairing status, the 6-digit code from the Mac, and a preview of the
/// Live Activity. Plain UIKit.
final class PairingViewController: UIViewController, UITextFieldDelegate {
    private let titleLabel = UILabel()
    private let subtitle = UILabel()
    private let status = UILabel()
    private let codeField = UITextField()
    private let pairButton = UIButton(configuration: .filled())
    private let previewButton = UIButton(configuration: .gray())
    private let note = UILabel()
    private let client = PairingClient()
    private var pairing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        titleLabel.text = "T3 Notch"
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white

        subtitle.text = "Your T3 Code threads on the Lock Screen, live, wherever you are. Pair once on the same Wi-Fi as your Mac; after that it updates over the internet."
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitle.numberOfLines = 0

        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.numberOfLines = 0

        codeField.placeholder = "6-digit code from the Mac"
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        codeField.textAlignment = .center
        codeField.textColor = .white
        codeField.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        codeField.layer.cornerRadius = 12
        codeField.delegate = self
        // Typed, pasted or autofilled: re-check on every edit.
        codeField.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .editingChanged)
        codeField.heightAnchor.constraint(equalToConstant: 56).isActive = true

        pairButton.configuration?.title = "Pair with Mac"
        pairButton.configuration?.baseBackgroundColor = UIColor(red: 0.49, green: 0.83, blue: 0.99, alpha: 1)
        pairButton.configuration?.baseForegroundColor = .black
        pairButton.configuration?.cornerStyle = .large
        pairButton.addAction(UIAction { [weak self] _ in self?.pair() }, for: .touchUpInside)

        previewButton.configuration?.title = "Preview the Live Activity"
        previewButton.configuration?.cornerStyle = .large
        previewButton.addAction(UIAction { [weak self] _ in self?.preview() }, for: .touchUpInside)

        note.text = "On the Mac: T3 Notch menu → Pair iPhone…"
        note.font = .systemFont(ofSize: 13)
        note.textColor = UIColor.white.withAlphaComponent(0.45)
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitle, status, codeField, pairButton, note, previewButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(28, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing)))
        NotificationCenter.default.addObserver(forName: PhoneState.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func refresh() {
        let token = PhoneState.pushToStartToken
        if !ActivityAuthorizationInfo().areActivitiesEnabled {
            show("Live Activities are off for T3 Notch. Turn them on in Settings → T3 Notch.", .systemOrange)
        } else if token == nil {
            show("Getting this iPhone's Live Activity address from iOS…", UIColor.white.withAlphaComponent(0.6))
        } else if let mac = PhoneState.pairedMac, PhoneState.pairedToken == token {
            show("Paired with \(mac). You can close this app.", UIColor(red: 0.43, green: 0.91, blue: 0.72, alpha: 1))
        } else if PhoneState.pairedMac != nil {
            show("iOS gave this iPhone a new address. Pair again to keep updates coming.", .systemOrange)
        } else {
            show("Not paired yet.", UIColor.white.withAlphaComponent(0.8))
        }
        pairButton.isEnabled = !pairing // checks the code when tapped, with a reason if it's not ready
    }

    private func show(_ text: String, _ color: UIColor) {
        status.text = text
        status.textColor = color
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let next = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
        guard next.count <= 6, next.allSatisfy(\.isNumber) else { return false }
        DispatchQueue.main.async { self.refresh() }
        return true
    }

    private func pair() {
        let code = (codeField.text ?? "").filter(\.isNumber)
        guard code.count == 6 else { show("Enter the 6-digit code shown on the Mac.", .systemOrange); return }
        guard let token = PhoneState.pushToStartToken else {
            show("iOS hasn't given this iPhone its Live Activity address yet. Wait a few seconds and try again.", .systemOrange)
            return
        }
        pairing = true
        view.endEditing(true)
        show("Looking for your Mac…", UIColor.white.withAlphaComponent(0.6))
        refresh()
        client.pair(PairingRequest(code: code, pushToStartToken: token, deviceName: UIDevice.current.name)) { [weak self] result in
            guard let self else { return }
            self.pairing = false
            switch result {
            case .success(let reply) where reply.ok:
                PhoneState.pairedMac = reply.macName ?? "your Mac"
                PhoneState.pairedToken = token
                self.codeField.text = ""
                self.refresh()
            case .success(let reply):
                self.refresh()
                self.show(reply.error ?? "The Mac said no.", .systemRed)
            case .failure(let error):
                self.refresh()
                self.show(error.localizedDescription, .systemRed)
            }
        }
    }

    /// A local sample, to see the Live Activity without waiting for the Mac.
    private func preview() {
        let now = Date().timeIntervalSince1970
        let state = NotchActivityAttributes.ContentState(
            rows: [
                LiveRow(id: "a", title: "Add dark mode to the dashboard", provider: "claudeAgent", status: "working",
                        activity: "Editing ThemeProvider.tsx", startedAt: now - 95, added: 37, removed: 12),
                LiveRow(id: "b", title: "Fix checkout flow regression", provider: "codex", status: "working",
                        activity: "$ pnpm test --filter checkout", startedAt: now - 754, added: 128, removed: 37),
                LiveRow(id: "c", title: "Clean up old build artifacts", provider: "cursor", status: "needsYou",
                        activity: "rm -rf .build T3Notch.app", startedAt: nil, added: 0, removed: 0),
            ],
            working: 2, needsYou: 1,
            event: LiveEvent(kind: "done", title: "Release notes for 2.4", text: "Drafted the notes and opened the PR.", at: now))
        Task {
            for activity in Activity<NotchActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            _ = try? Activity.request(attributes: NotchActivityAttributes(),
                                      content: .init(state: state, staleDate: Date().addingTimeInterval(600)))
        }
    }
}
