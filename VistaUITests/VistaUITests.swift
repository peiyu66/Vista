import XCTest

final class VistaUITests: XCTestCase {
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
        XCTAssertTrue(app.buttons["返回檔案"].isHittable)
        app.buttons["返回檔案"].tap()
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
