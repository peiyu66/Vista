import XCTest

final class VistaUITests: XCTestCase {
    @MainActor func testVRProjectionPatternOpensAndReturns() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10))
        app.buttons["openDemo"].tap()
        for folder in ["影片，資料夾", "電影，資料夾", "科幻，資料夾"] {
            XCTAssertTrue(app.buttons[folder].waitForExistence(timeout: 5)); app.buttons[folder].tap()
        }
        app.buttons["星際漫遊_SBS_180.mp4，檔案"].tap()
        XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openVR"].isEnabled)
        for (projection, layout) in [("等距柱狀 360°", "左右排列"), ("等距柱狀 180°", "上下排列")] {
            app.descendants(matching: .any)["vrProjection"].firstMatch.tap()
            app.buttons[projection].firstMatch.tap()
            app.descendants(matching: .any)["vrLayout"].firstMatch.tap()
            app.buttons[layout].firstMatch.tap()
            app.buttons["openVRTest"].tap()
            XCTAssertTrue(app.staticTexts["vrTestPattern"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["vrReady"].label, projection)
            XCTAssertEqual(app.staticTexts["vrLayoutReady"].label, layout)
            XCTAssertFalse(app.staticTexts["vrError"].exists)
            print("VR_VISUAL_READY", projection, layout)
            Thread.sleep(forTimeInterval: 3) // Allow the rendered test pattern to settle for external visual capture.
            app.buttons["向右轉"].tap()
            app.buttons["方向歸零"].tap()
            app.buttons["closeVR"].tap()
            XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.buttons["returnToBrowser"].waitForExistence(timeout: 5))
        app.buttons["returnToBrowser"].tap()
        XCTAssertTrue(app.buttons["星際漫遊_SBS_180.mp4，檔案"].waitForExistence(timeout: 5))
    }
    @MainActor func testVRFormatSurvivesRelaunchAndCanBeCleared() throws {
        let app = XCUIApplication()
        func openFixture() {
            XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10)); app.buttons["openDemo"].tap()
            for name in ["影片，資料夾", "電影，資料夾", "科幻，資料夾", "星際漫遊_SBS_180.mp4，檔案"] {
                XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5)); app.buttons[name].tap()
            }
            XCTAssertTrue(app.staticTexts["mediaHeader"].waitForExistence(timeout: 5))
        }
        app.launch(); openFixture()
        if app.buttons["clearVRFormat"].exists { app.buttons["clearVRFormat"].tap() }
        app.descendants(matching: .any)["vrProjection"].firstMatch.tap(); app.buttons["等距柱狀 360°"].firstMatch.tap()
        app.descendants(matching: .any)["vrLayout"].firstMatch.tap(); app.buttons["左右排列"].firstMatch.tap()
        XCTAssertTrue(app.buttons["clearVRFormat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["vrPreferenceError"].exists)
        app.terminate(); app.launch(); openFixture()
        XCTAssertTrue(app.buttons["clearVRFormat"].waitForExistence(timeout: 5))
        app.buttons["openVRTest"].tap()
        XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["vrReady"].label, "等距柱狀 360°")
        XCTAssertEqual(app.staticTexts["vrLayoutReady"].label, "左右排列")
        app.buttons["closeVR"].tap()
        XCTAssertTrue(app.buttons["clearVRFormat"].waitForExistence(timeout: 10)); app.buttons["clearVRFormat"].tap()
        app.terminate(); app.launch(); openFixture()
        XCTAssertFalse(app.buttons["clearVRFormat"].exists)
        XCTAssertFalse(app.staticTexts["vrPreferenceError"].exists)
    }
    @MainActor func testFisheyeCalibrationLayoutsAndPersistence() throws {
        let app = XCUIApplication()
        func openFixture() {
            XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10)); app.buttons["openDemo"].tap()
            for name in ["影片，資料夾", "電影，資料夾", "科幻，資料夾", "星際漫遊_SBS_180.mp4，檔案"] {
                XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5)); app.buttons[name].tap()
            }
            XCTAssertTrue(app.staticTexts["mediaHeader"].waitForExistence(timeout: 5))
        }
        app.launch(); openFixture()
        app.descendants(matching: .any)["vrProjection"].firstMatch.tap()
        app.buttons["等距魚眼 180°（置中圓）"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["fisheyeScope"].exists)
        for layout in ["單眼", "左右排列", "上下排列"] {
            app.descendants(matching: .any)["vrLayout"].firstMatch.tap(); app.buttons[layout].firstMatch.tap()
            app.buttons["openVRTest"].tap()
            XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["vrReady"].label, "等距魚眼 180°（置中圓）")
            XCTAssertEqual(app.staticTexts["vrLayoutReady"].label, layout)
            XCTAssertTrue(app.staticTexts["fisheyeCalibration"].exists)
            XCTAssertFalse(app.staticTexts["vrError"].exists)
            print("FISHEYE_VISUAL_READY", layout)
            Thread.sleep(forTimeInterval: 5)
            app.buttons["closeVR"].tap()
            XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 10))
        }
        app.terminate(); app.launch(); openFixture()
        XCTAssertTrue(app.staticTexts["fisheyeScope"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clearVRFormat"].exists)
        app.buttons["clearVRFormat"].tap()
        XCTAssertFalse(app.staticTexts["fisheyeScope"].exists)
    }
    @MainActor func testInitialPoseAndManualRecenter() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10)); app.buttons["openDemo"].tap()
        for name in ["影片，資料夾", "電影，資料夾", "科幻，資料夾", "星際漫遊_SBS_180.mp4，檔案"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5)); app.buttons[name].tap()
        }
        XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 5))
        app.buttons["openVRTest"].tap()
        XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
        let recenter = app.buttons["recenterVR"]
        XCTAssertTrue(recenter.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: recenter); waitForExpectations(timeout: 10)
        let initial = recenter.value as? String
        XCTAssertTrue(["已取得初始方向", "尚未取得初始方向"].contains(initial ?? ""))
        print("SIM_INITIAL_POSE_STATUS", initial ?? "missing")
        if initial == "尚未取得初始方向" { XCTAssertTrue(app.staticTexts["initialPoseUnavailable"].exists) }
        app.buttons["向上轉"].tap(); app.buttons["左傾"].tap(); app.buttons["方向歸零"].tap()
        recenter.tap()
        expectation(for: enabled, evaluatedWith: recenter); waitForExpectations(timeout: 10)
        print("SIM_RECENTER_STATUS", recenter.value as? String ?? "missing")
        app.buttons["closeVR"].tap()
        XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 10))
        app.buttons["openVRTest"].tap()
        XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
        XCTAssertTrue(recenter.waitForExistence(timeout: 10))
        XCTAssertEqual(recenter.value as? String, initial)
        app.buttons["closeVR"].tap()
    }
    @MainActor func testMetadataAppliesWithoutOverwritingManualFormat() throws {
        let app = XCUIApplication()
        func openFixture() {
            XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10)); app.buttons["openDemo"].tap()
            for name in ["影片，資料夾", "電影，資料夾", "科幻，資料夾", "格式標記示範.mp4，檔案"] {
                XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5)); app.buttons[name].tap()
            }
            XCTAssertTrue(app.staticTexts["mediaHeader"].waitForExistence(timeout: 5))
        }
        func verifyProjection(_ projection: String, _ layout: String) {
            app.buttons["openVRTest"].tap()
            XCTAssertTrue(app.staticTexts["vrReady"].waitForExistence(timeout: 30))
            XCTAssertEqual(app.staticTexts["vrReady"].label, projection)
            XCTAssertEqual(app.staticTexts["vrLayoutReady"].label, layout)
            app.buttons["closeVR"].tap()
            XCTAssertTrue(app.buttons["openVRTest"].waitForExistence(timeout: 10))
        }
        app.launch(); openFixture()
        if app.buttons["clearVRFormat"].exists { app.buttons["clearVRFormat"].tap() }
        XCTAssertTrue(app.staticTexts["vrMetadataStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["vrMetadataStatus"].label, "已依影片格式標記設定")
        XCTAssertFalse(app.buttons["clearVRFormat"].exists)
        verifyProjection("等距柱狀 360°", "上下排列")
        app.descendants(matching: .any)["vrProjection"].firstMatch.tap(); app.buttons["等距柱狀 180°"].firstMatch.tap()
        app.descendants(matching: .any)["vrLayout"].firstMatch.tap(); app.buttons["左右排列"].firstMatch.tap()
        XCTAssertTrue(app.buttons["clearVRFormat"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openFixture()
        XCTAssertTrue(app.buttons["clearVRFormat"].waitForExistence(timeout: 5))
        verifyProjection("等距柱狀 180°", "左右排列")
        app.buttons["clearVRFormat"].tap()
        XCTAssertTrue(app.staticTexts["vrMetadataStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vrMetadataStatus"].label, "已依影片格式標記設定")
        app.terminate(); app.launch(); openFixture()
        XCTAssertTrue(app.staticTexts["vrMetadataStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["vrMetadataStatus"].label, "已依影片格式標記設定")
        XCTAssertFalse(app.buttons["clearVRFormat"].exists)
    }
    @MainActor func testConnectionValidationAndKeyboardSubmit() throws {
        let app = XCUIApplication()
        app.launch()
        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        XCTAssertTrue(app.staticTexts["connectionMessage"].waitForExistence(timeout: 3))
        // An invalid form must give feedback without making a network request.
        app.terminate()
        app.launch()
        let password = app.secureTextFields["passwordField"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("fixture-only\n")
        XCTAssertTrue(app.staticTexts["connectionMessage"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.progressIndicators["connectionProgress"].exists)
    }
    @MainActor func testTwoColumnsHardwareVideoAndReturn() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 10))
        app.buttons["openDemo"].tap()
        XCTAssertTrue(app.buttons["影片，資料夾"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["serverTitle"].label, "伺服器：示範伺服器")
        XCTAssertEqual(app.staticTexts["shareTitle"].label, "分享：示範分享")
        XCTAssertEqual(app.staticTexts["directoryPath"].label, "/")
        XCTAssertEqual(app.staticTexts["currentDirectoryTitle"].label, "示範分享")
        XCTAssertFalse(app.staticTexts["已在最上層"].exists)
        XCTAssertFalse(app.staticTexts["分享根目錄"].exists)
        XCTAssertFalse(app.buttons["back"].isEnabled)
        app.buttons["影片，資料夾"].tap()
        XCTAssertTrue(app.buttons["電影，資料夾"].waitForExistence(timeout: 5))
        app.buttons["電影，資料夾"].tap()
        XCTAssertTrue(app.buttons["科幻，資料夾"].waitForExistence(timeout: 5))
        app.buttons["科幻，資料夾"].tap()
        XCTAssertTrue(app.buttons["星際漫遊_SBS_180.mp4，檔案"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["serverTitle"].label, "伺服器：示範伺服器")
        XCTAssertEqual(app.staticTexts["shareTitle"].label, "分享：示範分享")
        XCTAssertEqual(app.staticTexts["directoryPath"].label, "/影片/電影/科幻")
        app.buttons["星際漫遊_SBS_180.mp4，檔案"].tap()
        XCTAssertTrue(app.buttons["playVideo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mediaHeader"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mediaHeader"].label, "檔頭：ISO BMFF（MP4 家族）")
        if app.buttons["clearVRFormat"].exists { app.buttons["clearVRFormat"].tap() }
        XCTAssertTrue(app.staticTexts["vrMetadataStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["vrMetadataStatus"].label, "未找到格式標記，請手動選擇。")
        XCTAssertTrue(app.buttons["confirmVRFormat"].exists)
        app.buttons["playVideo"].tap()
        let status = app.staticTexts["playbackStatus"]
        let finished = NSPredicate(format: "label == %@ OR label == %@", "播放結束", "無法確認硬體解碼，已停止播放。")
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 20)
        print("SIM_PLAYBACK_STATUS", status.label)
        XCTAssertTrue(app.staticTexts["videoTrackInfo"].exists)
        XCTAssertTrue(app.staticTexts["playbackTime"].exists)
        XCTAssertFalse(app.buttons["pauseResumeVideo"].exists)
        if status.label == "無法確認硬體解碼，已停止播放。" {
            XCTAssertEqual(app.staticTexts["playbackTime"].label, "00:00 / 00:02")
        }
        if status.label == "播放結束" {
            app.buttons["playVideo"].tap()
            XCTAssertTrue(app.buttons["stopVideo"].waitForExistence(timeout: 3))
            app.buttons["stopVideo"].tap()
            XCTAssertEqual(status.label, "已停止")
        }
        let position = app.sliders["playbackPosition"]
        XCTAssertTrue(position.exists)
        app.buttons["skipForward"].tap()
        XCTAssertEqual(status.label, "播放結束")
        XCTAssertEqual(app.staticTexts["playbackTime"].label, "00:02 / 00:02")
        app.buttons["skipBackward"].tap()
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 20)
        // Slider adjustment/drag is not automated by this visionOS runtime; see acceptance notes.
        XCTAssertTrue(app.buttons["returnToBrowser"].isHittable)
        app.buttons["returnToBrowser"].tap()
        XCTAssertTrue(app.buttons["星際漫遊_SBS_180.mp4，檔案"].waitForExistence(timeout: 5))
        app.buttons["back"].tap()
        XCTAssertTrue(app.buttons["科幻，資料夾"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["旅行，資料夾"].exists)
        app.buttons["旅行，資料夾"].tap()
        XCTAssertTrue(app.buttons["示範影片.mp4，檔案"].waitForExistence(timeout: 5))
        app.buttons["離開分享"].tap()
        XCTAssertTrue(app.buttons["openDemo"].waitForExistence(timeout: 5))
        app.buttons["openDemo"].tap()
        XCTAssertTrue(app.buttons["影片，資料夾"].waitForExistence(timeout: 5))
        app.buttons["影片，資料夾"].tap()
        XCTAssertTrue(app.buttons["電影，資料夾"].waitForExistence(timeout: 5))
        app.buttons["電影，資料夾"].tap()
        XCTAssertTrue(app.buttons["科幻，資料夾"].waitForExistence(timeout: 5))
    }
}
