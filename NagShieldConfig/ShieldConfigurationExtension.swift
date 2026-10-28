import ManagedSettings
import ManagedSettingsUI
import NagKit
import UIKit

/// The screen shown in place of a blocked app: which lock is holding it and what's left to do.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration(application: application.token)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(application: application.token, category: category.token)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration(webDomain: webDomain.token)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(category: category.token, webDomain: webDomain.token)
    }

    private func makeConfiguration(
        application: ApplicationToken? = nil,
        category: ActivityCategoryToken? = nil,
        webDomain: WebDomainToken? = nil
    ) -> ShieldConfiguration {
        let state = SharedStore.shared.load()
        let now = Date()
        let profile = ShieldController.profile(in: state, now: now, application: application, category: category, webDomain: webDomain)
        let remaining = profile.map { profile in
            UnlockEvaluator.evaluate(profile, state: state, steps: nil, now: now, calendar: .current)
                .filter { !$0.isMet }
                .map(\.title)
        } ?? []

        var subtitle = profile?.message ?? "Nag is keeping this closed for now."
        if !remaining.isEmpty {
            subtitle += "\n\nTo unlock: " + remaining.joined(separator: " · ")
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterialDark,
            backgroundColor: UIColor(red: 0.16, green: 0.07, blue: 0.04, alpha: 0.85),
            icon: UIImage(systemName: "bell.badge.fill")?.withTintColor(.systemOrange, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: profile.map { "\($0.name) is locked" } ?? "Locked by Nag", color: .white),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: UIColor(white: 0.88, alpha: 1)),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Unlock in Nag", color: .white),
            primaryButtonBackgroundColor: .systemOrange,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Close", color: .systemOrange)
        )
    }
}
