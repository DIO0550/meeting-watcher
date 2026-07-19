//
//  ファイル: meeting_watcherUITestsLaunchTests.swift
//  ターゲット: meeting-watcherUITests
//
//  作成者: DIO（2026/06/20）
//

import XCTest

final class meeting_watcherUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // アプリ起動後、スクリーンショットを撮影する前に実行する手順をここに追加します。
        // テストアカウントへのログインやアプリ内の画面遷移などを記述します。
        // XCUIAutomationのドキュメント
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
