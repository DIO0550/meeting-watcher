//
//  ファイル: meeting_watcherUITests.swift
//  ターゲット: meeting-watcherUITests
//
//  作成者: DIO（2026/06/20）
//

import XCTest

final class meeting_watcherUITests: XCTestCase {

    override func setUpWithError() throws {
        // ここにセットアップコードを記述します。このメソッドは各テストメソッドの呼び出し前に実行されます。

        // UIテストでは、失敗が発生したらすぐに停止するのが一般的です。
        continueAfterFailure = false

        // UIテストでは、インターフェースの向きなど、テストの実行に必要な初期状態を事前に設定することが重要です。
        // setUpメソッドはその設定に適しています。
    }

    override func tearDownWithError() throws {
        // ここに後片付けコードを記述します。このメソッドは各テストメソッドの呼び出し後に実行されます。
    }

    @MainActor
    func testExample() throws {
        // UIテストでは、テスト対象のアプリケーションを起動する必要があります。
        let app = XCUIApplication()
        app.launch()

        // XCTAssertなどの関数を使って、テストが正しい結果を返すことを検証します。
        // XCUIAutomationのドキュメント
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // アプリケーションの起動にかかる時間を測定します。
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
