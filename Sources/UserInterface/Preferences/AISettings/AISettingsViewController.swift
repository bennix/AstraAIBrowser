// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Settings

class AISettingsViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.aisettings
    var paneTitle: String = NSLocalizedString("settings.navigation.aiTitle", value: "ZenMux AI", comment: "Settings - Tab title for ZenMux AI settings")
    var toolbarItemIcon: NSImage = {
        guard let symbol = NSImage(systemSymbolName: "sparkles",
                                   accessibilityDescription: "ZenMux AI")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else {
            return NSImage()
        }
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2,
                                   y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }()

    let hostingController = AISettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}

extension Notification.Name {
    static let browserMemorySwitchDidChange = Notification.Name("browserMemorySwitchDidChange")
}
