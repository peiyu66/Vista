import XCTest
final class VistaUITests:XCTestCase {
    private var expectedFrameState:String {
        #if VISTA_SYSTEM_VIDEO_EXPERIMENT
        "影格已提交"
        #else
        "影像已呈現"
        #endif
    }
    @MainActor func fresh(narrow:Bool=false,extra:[String]=[]) -> XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture"]+(narrow ? ["--narrow-list"]:[])+extra;app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));return app
    }
    @MainActor func waitForTags(_ app:XCUIApplication,count:Int,timeout:TimeInterval=100) {
        let path=app.staticTexts["prototypePath"]
        let done=NSPredicate(format:"value == %@","tags-complete:\(count)")
        expectation(for:done,evaluatedWith:path);waitForExpectations(timeout:timeout)
        XCTAssertFalse(app.staticTexts["tagSortStatus"].exists)
    }
    @MainActor func testSidebarFirstAndLastRowInsetsAcrossHeights() throws {
        let app=XCUIApplication()
        app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--long-shortcuts","--window-resize-test","--sidebar-inset-test"]
        app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10))
        app.buttons["editShortcuts"].tap();app.buttons["shortcut-Folder 01"].tap()
        let scroll=app.scrollViews["shortcutSidebarScroll"]
        for size in ["testShortWindow","testTallWindow"] {
            app.buttons[size].tap()
            let first=app.buttons["shortcut-Folder 01"]
            for _ in 0..<12 {if first.isHittable {break};scroll.swipeDown()}
            scroll.swipeDown()
            XCTAssertTrue(first.isHittable)
            XCTAssertGreaterThanOrEqual(first.frame.minY-scroll.frame.minY,10)
            let last=app.buttons["shortcut-Folder 40"]
            for _ in 0..<12 {if last.isHittable {break};scroll.swipeUp()}
            scroll.swipeUp()
            XCTAssertTrue(last.isHittable)
            XCTAssertGreaterThanOrEqual(scroll.frame.maxY-last.frame.maxY,14)
            XCTAssertTrue(app.staticTexts["browserAppVersion"].isHittable)
        }
    }
    @MainActor func testBlueRoundedVisualStates() throws {
        func capture(_ name:String) {
            let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
        }
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["smbDemoSource"].tap()
        capture("source-capsule")
        app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        capture("source-capsule-folder")
        app.buttons["entry-影片"].tap();app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["shortcut-影片"].tap()
        XCTAssertTrue(app.buttons["sort-name"].waitForExistence(timeout:5));app.buttons["sort-name"].tap()
        capture("header-selected-folders")
        app.buttons["entry-電影"].tap()
        XCTAssertTrue(app.buttons["parent-電影"].waitForExistence(timeout:5))
        capture("parent-capsule")
    }
    @MainActor func testBrowserVersionRemainsAtBottomAcrossModesAndSizes() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--window-resize-test"];app.launch()
        let version=app.staticTexts["browserAppVersion"]
        XCTAssertTrue(version.waitForExistence(timeout:10));XCTAssertTrue(version.isHittable)
        let value=try XCTUnwrap(version.value as? String)
        XCTAssertNotNil(value.range(of:#"^[0-9]+\.[0-9]+\.[0-9]+ \([0-9]+\)$"#,options:.regularExpression))
        let top=app.buttons["editShortcuts"]
        XCTAssertGreaterThan(version.frame.minY,top.frame.maxY)
        app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertEqual(version.frame.minX,app.buttons["localDemoSource"].frame.minX+10,accuracy:2)
        for id in ["testNarrowWindow","testWideWindow"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout:10));app.buttons[id].tap()
            XCTAssertTrue(version.isHittable);XCTAssertEqual(version.value as? String,value)
            XCTAssertGreaterThan(version.frame.minY,top.frame.maxY)
        }
        app.buttons["editShortcuts"].tap();XCTAssertTrue(version.isHittable)
    }
    @MainActor func testLocalSourceDisplayRenamePreservesFolderAndShortcut() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--local-files-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        app.buttons["savedLocalSource"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        app.buttons["addShortcut"].tap()
        let capsuleImage=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capsuleImage.name="local-and-shortcut-edit-capsules";capsuleImage.lifetime = .keepAlways;add(capsuleImage)
        let name=app.descendants(matching:.any).matching(identifier:"localSourceName").firstMatch;XCTAssertTrue(name.exists);name.tap();name.typeText(" Cancelled")
        app.buttons["cancelLocalSourceName"].tap()
        XCTAssertEqual(name.value as? String,"Local Test Folder")
        name.tap()
        name.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:(name.value as? String ?? "").count))
        name.typeText("My Local Movies\n")
        XCTAssertTrue(app.buttons["savedLocalSource"].label.contains("My Local Movies"))
        app.buttons["savedLocalSource"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["shortcut-VistaLocalUITestFixture"].exists)
        app.terminate();app.launchArguments=["--shortcut-ui-tests","--local-files-fixture"];app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["savedLocalSource"].label.contains("My Local Movies"))
        app.buttons["savedLocalSource"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        app.buttons["entry-Child"].tap()
        XCTAssertTrue(app.buttons["entry-Grandchild"].waitForExistence(timeout:10))
    }
    @MainActor func testLocalFolderBrowseShortcutAndRestart() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--local-files-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        XCTAssertFalse(app.buttons["localDemoSource"].exists)
        app.buttons["savedLocalSource"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["entry-.hidden"].exists)
        app.buttons["addShortcut"].tap()
        app.buttons["entry-Child"].tap()
        XCTAssertTrue(app.buttons["entry-Grandchild"].waitForExistence(timeout:10))
        app.buttons["addShortcut"].tap()
        app.buttons["folderBack"].tap()
        app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["shortcut-Child"].exists)
        app.buttons["shortcut-VistaLocalUITestFixture"].tap()
        app.buttons["entry-Child"].tap()
        XCTAssertTrue(app.buttons["entry-Grandchild"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["shortcutHome"].exists)
        app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        app.terminate();app.launchArguments=["--shortcut-ui-tests","--local-files-fixture"];app.launch()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["shortcut-VistaLocalUITestFixture"].exists)
        XCTAssertTrue(app.buttons["shortcut-Child"].exists)
        app.buttons["editShortcuts"].tap();app.buttons["savedLocalSource"].tap()
        XCTAssertTrue(app.buttons["entry-visible.txt"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["chooseLocalFolder"].exists)
        app.buttons["entry-Child"].tap()
        XCTAssertTrue(app.buttons["entry-Grandchild"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["addShortcut"].isEnabled)
    }
    @MainActor func testSystemFolderPickerCanCancel() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["chooseLocalFolder"].tap()
        let cancel=app.buttons.matching(NSPredicate(format:"label == %@ OR label == %@","取消","Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:15),app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.buttons["chooseLocalFolder"].waitForExistence(timeout:10))
    }
    @MainActor func testBrowserDirectImmersiveNextAndStopRestore() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-H264 播放測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveStop"].waitForExistence(timeout:25),app.debugDescription)
        XCTAssertEqual(app.staticTexts["immersiveFileTitle"].label,"H264 播放測試.mp4")
        XCTAssertTrue(app.buttons["immersiveNext"].isEnabled)
        XCTAssertFalse(app.buttons["immersivePrevious"].isEnabled)
        let controls=["immersivePrevious","immersiveBack","immersivePause","immersiveForward","immersiveNext"].map { app.buttons[$0] }
        for i in 1..<controls.count { XCTAssertLessThan(controls[i-1].frame.midX,controls[i].frame.midX) }
        XCTAssertLessThan(app.buttons["immersiveStop"].frame.midY,controls[0].frame.midY)
        app.buttons["immersiveSettings"].tap()
        expectation(for:NSPredicate(format:"value == %@",expectedFrameState),evaluatedWith:app.staticTexts["immersiveFileTitle"])
        waitForExpectations(timeout:15)
        XCTAssertTrue(app.buttons["projection-equirectangular180"].waitForExistence(timeout:5))
        #if VISTA_SYSTEM_VIDEO_EXPERIMENT && VISTA_DIAGNOSTIC_UI
        XCTAssertTrue(app.staticTexts["systemVideoCandidate"].label.contains("送入 renderer"))
        #endif
        let info=app.staticTexts["controllerVideoInfo"]
        XCTAssertTrue(info.waitForExistence(timeout:5));XCTAssertTrue(info.label.contains("avc1") || info.label.contains("H.264"))
        XCTAssertGreaterThanOrEqual(info.frame.minY,app.staticTexts["resetControllerGestureHint"].frame.maxY)
        app.buttons["immersiveNext"].tap()
        let title=app.staticTexts["immersiveFileTitle"]
        expectation(for:NSPredicate(format:"label == %@","HEVC 播放測試.mp4"),evaluatedWith:title)
        waitForExpectations(timeout:20)
        expectation(for:NSPredicate(format:"value == %@",expectedFrameState),evaluatedWith:title)
        waitForExpectations(timeout:20)
        XCTAssertTrue(app.buttons["immersiveNext"].isEnabled)
        XCTAssertTrue(app.buttons["immersivePrevious"].isEnabled)
        XCTAssertTrue(app.buttons["recenterVideo"].exists)
        XCTAssertTrue(info.label.contains("hvc1") || info.label.contains("hev1") || info.label.contains("HEVC"))
        app.buttons["immersivePrevious"].tap()
        expectation(for:NSPredicate(format:"label == %@","H264 播放測試.mp4"),evaluatedWith:title)
        waitForExpectations(timeout:20)
        XCTAssertFalse(app.buttons["immersivePrevious"].isEnabled)
        XCTAssertTrue(app.buttons["recenterVideo"].exists)
        app.buttons["immersiveSettings"].tap()
        XCTAssertFalse(app.buttons["recenterVideo"].exists)
        app.buttons["immersiveNext"].tap()
        expectation(for:NSPredicate(format:"label == %@","HEVC 播放測試.mp4"),evaluatedWith:title)
        waitForExpectations(timeout:20)
        XCTAssertFalse(app.buttons["recenterVideo"].exists)
        app.buttons["immersiveSettings"].tap()
        XCTAssertTrue(app.buttons["recenterVideo"].exists)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-HEVC 播放測試.mp4"].waitForExistence(timeout:15))
        XCTAssertEqual(app.buttons["entry-HEVC 播放測試.mp4"].value as? String,"已選取")
        XCTAssertTrue(app.staticTexts["prototypePath"].label.contains("播放測試"))
        app.buttons["entry-HEVC 播放測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:25))
        XCTAssertFalse(app.buttons["recenterVideo"].exists)
        app.buttons["immersiveStop"].tap()
    }
    @MainActor func testPerformanceDiagnosticWindowAndStop() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        XCTAssertTrue(app.buttons["playbackDiagnostics"].waitForExistence(timeout:25))
        app.buttons["playbackDiagnostics"].tap()
        let result=app.staticTexts["playbackDiagnosticsResult"]
        XCTAssertTrue(result.waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"label CONTAINS %@","已結束 10.0 秒"),evaluatedWith:result)
        waitForExpectations(timeout:20)
        XCTAssertTrue(result.label.contains("來源：合成"))
        XCTAssertTrue(result.label.contains("模擬器軟解測試"))
        XCTAssertTrue(result.label.contains("同步丟幀"))
        XCTAssertFalse(result.label.contains("控制器互動測試.mp4"))
        XCTAssertTrue(app.buttons["immersiveStop"].isHittable)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:15))
    }
    @MainActor func testProgressTimeFollowsSeekAndStops() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:25));app.buttons["immersiveSettings"].tap()
        XCTAssertEqual(app.buttons["immersiveForward"].label,"前進 30 秒")
        XCTAssertEqual(app.buttons["immersiveBack"].label,"後退 30 秒")
        let pause=app.buttons["immersivePause"]
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","暫停"),evaluatedWith:pause);waitForExpectations(timeout:15)
        pause.tap()
        let slider=app.sliders["playbackSeek"]
        XCTAssertTrue(slider.waitForExistence(timeout:5));XCTAssertTrue(slider.isEnabled)
        XCTAssertEqual(app.staticTexts["playbackDuration"].label,"02:00")
        app.buttons["immersiveForward"].tap()
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","播放"),evaluatedWith:pause);waitForExpectations(timeout:15)
        let elapsed=app.staticTexts["playbackElapsed"].label
        XCTAssertTrue(["00:29","00:30","00:31","00:32","00:33","00:34"].contains(elapsed),elapsed)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:15))
    }
    @MainActor private func openSystemFixture(extra:[String]=[])->XCUIApplication {
        let app=fresh(extra:extra);app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:25));app.buttons["immersiveSettings"].tap()
        return app
    }
    @MainActor func testSystemProbePackingAndFallback() throws {
        let app=openSystemFixture(extra:["--system-renderer-probe"])
        app.buttons["projection-equirectangular180"].tap()
        XCTAssertEqual(app.buttons["immersiveForward"].label,"前進 30 秒")
        XCTAssertEqual(app.buttons["immersiveBack"].label,"後退 30 秒")
        let pause=app.buttons["immersivePause"]
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","暫停"),evaluatedWith:pause);waitForExpectations(timeout:15)
        pause.tap()
        let probe=app.staticTexts["systemVideoProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout:5))
        print("SYSTEM_RENDERER_PROBE",probe.label)
        let route=app.staticTexts["systemVideoCandidate"]
        app.buttons["layout-overUnder"].tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","送入 renderer"),evaluatedWith:route);waitForExpectations(timeout:10)
        XCTAssertFalse(app.switches["swapVREyes"].exists)
        app.buttons["projection-equidistantFisheye180"].tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","魚眼投影"),evaluatedWith:route);waitForExpectations(timeout:10)
        app.buttons["projection-equirectangular360"].tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","送入 renderer"),evaluatedWith:route);waitForExpectations(timeout:10)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:15))
    }
    @MainActor func testCalibrationHoldForObservation() throws {try calibrationObservation(extra:[])}
    @MainActor func testSystemSBS360Observation() throws {try calibrationObservation(extra:[],file:"L-R SBS 360.mp4")}
    @MainActor func testSystemOU360Observation() throws {try calibrationObservation(extra:[],file:"L-R OU 360.mp4")}
    @MainActor func testSystemFlatPreviewThenImmersive() throws {
        let app=fresh(extra:["--flat-preview-test"])
        app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-立體校準"].waitForExistence(timeout:10));app.buttons["entry-立體校準"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap();app.buttons["entry-L-R SBS 180.mp4"].tap()
        let play=app.buttons["playVideo"];XCTAssertTrue(play.waitForExistence(timeout:15))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:play);waitForExpectations(timeout:15);play.tap()
        XCTAssertTrue(app.images["decodedVideoFrame"].waitForExistence(timeout:15))
        app.buttons["pauseResumeVideo"].tap()
        app.scrollViews.containing(.image,identifier:"decodedVideoFrame").firstMatch.swipeDown();app.images["decodedVideoFrame"].tap()
        print("FLAT_PREVIEW_READY")
        let hold=expectation(description:"Preview observation")
        DispatchQueue.main.asyncAfter(deadline:.now()+20){hold.fulfill()};wait(for:[hold],timeout:25)
        XCTAssertTrue(app.buttons["openVR"].isEnabled);app.buttons["openVR"].tap()
        XCTAssertTrue(app.buttons["immersiveStop"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["systemVideoCandidate"].exists)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-L-R SBS 180.mp4"].waitForExistence(timeout:15))
    }
    @MainActor func testSystemOUObservation() throws {try calibrationObservation(extra:[],file:"L-R OU 180.mp4")}
    @MainActor func testSystemFlatAPMPObservation() throws {try calibrationObservation(extra:["--system-renderer-flat"])}
    @MainActor func testSystemFlatRawObservation() throws {try calibrationObservation(extra:["--system-renderer-flat","--system-renderer-raw"])}
    @MainActor private func calibrationObservation(extra:[String],file:String="L-R SBS 180.mp4") throws {
        let app=fresh(extra:["--system-renderer-probe"]+extra);app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-立體校準"].waitForExistence(timeout:10));app.buttons["entry-立體校準"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-\(file)"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:25));app.buttons["immersiveSettings"].tap()
        XCTAssertEqual(app.buttons["immersiveForward"].label,"前進 30 秒")
        XCTAssertEqual(app.buttons["immersiveBack"].label,"後退 30 秒")
        let pause=app.buttons["immersivePause"]
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","暫停"),evaluatedWith:pause);waitForExpectations(timeout:15)
        pause.tap()
        #if VISTA_SYSTEM_VIDEO_EXPERIMENT
        XCTAssertTrue(app.staticTexts["systemVideoCandidate"].exists)
        #else
        XCTAssertTrue(app.staticTexts["baselineVideoPath"].exists)
        #endif
        print("CALIBRATION_READY_FOR_OBSERVATION")
        let hold=expectation(description:"Bounded manual observation window")
        DispatchQueue.main.asyncAfter(deadline:.now()+30) {hold.fulfill()}
        wait(for:[hold],timeout:35)
        if app.staticTexts["systemVideoProbe"].exists {print("OBSERVATION_PROBE: " + app.staticTexts["systemVideoProbe"].label)}
        app.buttons["immersiveStop"].tap()
    }
    @MainActor func testSystemFailureStopsAndCanReturn() throws {
        let app=openSystemFixture(extra:["--system-renderer-failure"])
        let error=app.staticTexts["immersiveMessage"]
        XCTAssertTrue(error.waitForExistence(timeout:10))
        XCTAssertTrue(error.label.contains("videoRenderer/injected"),error.label)
        XCTAssertEqual(app.buttons["immersivePause"].label,"播放")
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:15))
    }
    @MainActor func testSystemCandidateRepeatedSeekAndStop() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:25));app.buttons["immersiveSettings"].tap()
        // The preceding format-persistence test intentionally leaves fish-eye selected.
        // Explicitly establish the system renderer projection for this independent test.
        let projection=app.buttons["projection-equirectangular180"]
        XCTAssertTrue(projection.waitForExistence(timeout:5));projection.tap()
        XCTAssertEqual(app.buttons["immersiveForward"].label,"前進 30 秒")
        XCTAssertEqual(app.buttons["immersiveBack"].label,"後退 30 秒")
        let pause=app.buttons["immersivePause"]
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","暫停"),evaluatedWith:pause);waitForExpectations(timeout:15)
        pause.tap()
        for button in ["immersiveForward","immersiveBack","immersiveForward","immersiveBack"] {
            app.buttons[button].tap()
            expectation(for:NSPredicate(format:"label == %@ AND enabled == true","播放"),evaluatedWith:pause);waitForExpectations(timeout:15)
            let candidate=app.staticTexts["systemVideoCandidate"]
            expectation(for:NSPredicate(format:"label CONTAINS %@","送入 renderer"),evaluatedWith:candidate);waitForExpectations(timeout:10)
            XCTAssertEqual(candidate.value as? String,"materialInstances=1")
        }
        app.buttons["playbackDiagnostics"].tap()
        let timings=app.staticTexts["playbackDiagnosticsResult"]
        expectation(for:NSPredicate(format:"label CONTAINS %@","呈現通知"),evaluatedWith:timings);waitForExpectations(timeout:5)
        if app.staticTexts["systemVideoCandidate"].label.contains("AVPlayer") {
            XCTAssertTrue(timings.label.contains("系統管理（未知）"))
            XCTAssertTrue(timings.label.contains("已緩衝："))
            #if VISTA_ANON_IO_EXPERIMENT
            XCTAssertTrue(timings.label.contains("呈現 I/O 起"),timings.label)
            XCTAssertTrue(timings.label.contains("溢0"),timings.label)
            #endif
            XCTAssertTrue(timings.label.contains("renderer enqueue"))
        } else {
            XCTAssertTrue(timings.label.contains("舊播放清理"))
            XCTAssertTrue(timings.label.contains("落點"))
            XCTAssertTrue(timings.label.contains("音訊與時鐘就緒"))
        }
        Thread.sleep(forTimeInterval:12)
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertEqual(app.staticTexts["systemVideoCandidate"].value as? String,"materialInstances=1")
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:15))
    }
    @MainActor func testLongSyntheticPauseResume() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:20))
        app.buttons["immersiveSettings"].tap()
        XCTAssertEqual(app.buttons["immersiveForward"].label,"前進 30 秒")
        XCTAssertEqual(app.buttons["immersiveBack"].label,"後退 30 秒")
        let pause=app.buttons["immersivePause"]
        expectation(for:NSPredicate(format:"label == %@ AND enabled == true","暫停"),evaluatedWith:pause)
        waitForExpectations(timeout:15)
        pause.tap()
        expectation(for:NSPredicate(format:"label == %@","播放"),evaluatedWith:pause)
        waitForExpectations(timeout:5)
        pause.tap()
        expectation(for:NSPredicate(format:"label == %@","暫停"),evaluatedWith:pause)
        waitForExpectations(timeout:5)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:10))
    }
    @MainActor private func openPreparationFixture(_ flag:String)->XCUIApplication {
        let app=XCUIApplication()
        app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture",flag];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-H264 播放測試.mp4"].tap()
        return app
    }
    @MainActor func testStopDuringImmersivePreparationRestoresBrowser() throws {
        let app=openPreparationFixture("--slow-media-preparation")
        XCTAssertTrue(app.buttons["immersiveStop"].waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["immersiveNext"].isEnabled)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-H264 播放測試.mp4"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["entry-H264 播放測試.mp4"].value as? String,"已選取")
    }
    @MainActor func testReadFailureKeepsImmersiveStopAvailable() throws {
        let app=openPreparationFixture("--failed-media-preparation")
        XCTAssertTrue(app.staticTexts["immersiveMessage"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["immersiveMessage"].label.contains("無法讀取影片"))
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-H264 播放測試.mp4"].waitForExistence(timeout:10))
    }
    @MainActor func testControllerMoveHandleDoesNotReplaceButtons() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-播放測試"].waitForExistence(timeout:10));app.buttons["entry-播放測試"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-控制器互動測試.mp4"].tap()
        let title=app.staticTexts["immersiveFileTitle"]
        XCTAssertTrue(title.waitForExistence(timeout:25))
        app.buttons["immersiveSettings"].tap()
        let reset=app.buttons["resetControllerPosition"]
        XCTAssertTrue(reset.waitForExistence(timeout:5))
        XCTAssertTrue(reset.exists)
        XCTAssertTrue(app.staticTexts["resetControllerGestureHint"].exists)
        reset.tap();XCTAssertTrue(reset.exists)
        app.buttons["immersiveStop"].tap()
        XCTAssertTrue(app.buttons["entry-控制器互動測試.mp4"].waitForExistence(timeout:10))
    }
    @MainActor func testRingCoordinateEventProbe() throws {
        let app=XCUIApplication();app.launchArguments=["--controller-layout-review"];app.launch()
        let zero=app.buttons["directionZero"], right=app.buttons["directionRight"]
        XCTAssertTrue(zero.waitForExistence(timeout:10))
        for (name,x,y) in [("center",0.5,0.5),("label",0.568,0.5),("arcEdge",0.65,0.25)] {
            zero.tap()
            right.coordinate(withNormalizedOffset:CGVector(dx:x,dy:y)).tap()
            print("COORDINATE_PROBE \(name) result=\(zero.value ?? "nil") right=\(right.frame)")
        }
        zero.tap();right.tap()
        print("ELEMENT_PROBE result=\(zero.value ?? "nil")")
        XCTAssertTrue((zero.value as? String ?? "").contains("yaw=15"))
        app.terminate()
    }
    @MainActor func testRingEdgeCoordinateHitWhenSupported() throws {
        let app=XCUIApplication();app.launchArguments=["--controller-layout-review"];app.launch()
        defer { app.terminate() }
        let zero=app.buttons["directionZero"],right=app.buttons["directionRight"]
        XCTAssertTrue(zero.waitForExistence(timeout:10))
        right.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        guard (zero.value as? String ?? "").contains("yaw=15") else {
            zero.tap();right.tap()
            XCTAssertTrue((zero.value as? String ?? "").contains("yaw=15"))
            throw XCTSkip("Coordinate center event does not activate this visionOS simulator control; element activation succeeds. Edge hit remains unverified.")
        }
        zero.tap()
        right.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.25)).tap()
        XCTAssertTrue((zero.value as? String ?? "").contains("yaw=15"))
    }
    @MainActor func testCurvedDirectionAndResetRegions() throws {
        for large in [false,true] {
            let app=XCUIApplication();app.launchArguments=["--controller-layout-review"]+(large ? ["--review-large-text"]:[]);app.launch()
            let zero=app.buttons["directionZero"]
            XCTAssertTrue(zero.waitForExistence(timeout:10))
            XCTAssertTrue(app.staticTexts["videoFormatHeading"].exists)
            XCTAssertTrue(app.staticTexts["manualHorizontalAngle"].label.contains("0°"))
            XCTAssertEqual(app.staticTexts["manualVerticalAngle"].label,"0°")
            XCTAssertTrue(app.staticTexts["resetControllerGestureHint"].label.contains("三擊重設影片方向"))
            XCTAssertEqual(app.buttons["clearVRFormat"].label,"重設影片格式")
            for id in ["directionUp","directionLeft","directionRight","directionDown","recenterVideo","resetControllerPosition","clearVRFormat"] {XCTAssertTrue(app.buttons[id].isHittable)}
            app.buttons["directionUp"].tap();XCTAssertTrue((zero.value as? String ?? "").contains("pitch=15"))
            app.buttons["directionDown"].tap();XCTAssertTrue((zero.value as? String ?? "").contains("pitch=0"))
            app.buttons["directionLeft"].tap();XCTAssertTrue((zero.value as? String ?? "").contains("yaw=-15"))
            app.buttons["directionRight"].tap();XCTAssertTrue((zero.value as? String ?? "").contains("yaw=0"))
            app.buttons["directionLeft"].tap()
            app.buttons["projection-equidistantFisheye180"].tap();app.buttons["layout-overUnder"].tap()
            app.buttons["clearVRFormat"].tap()
            XCTAssertEqual(app.buttons["projection-equirectangular180"].value as? String,"已選取")
            XCTAssertEqual(app.buttons["layout-sideBySide"].value as? String,"已選取")
            XCTAssertTrue((zero.value as? String ?? "").contains("yaw=-15"))
            app.buttons["resetControllerPosition"].tap();XCTAssertTrue((zero.value as? String ?? "").contains("yaw=-15"))
            app.buttons["recenterVideo"].tap()
            XCTAssertEqual(app.buttons["projection-equirectangular180"].value as? String,"已選取")
            XCTAssertEqual(app.buttons["layout-sideBySide"].value as? String,"已選取")
            zero.tap();XCTAssertEqual(zero.value as? String,"yaw=0,pitch=0,roll=0")
            app.terminate()
        }
    }
    @MainActor func testClearSavedFormatKeepsDirectionAndResetsPersistence() throws {
        let app=openSystemFixture()
        app.buttons["projection-equirectangular360"].tap();app.buttons["layout-overUnder"].tap();app.buttons["directionLeft"].tap()
        app.buttons["clearVRFormat"].tap()
        XCTAssertTrue((app.buttons["directionZero"].value as? String ?? "").contains("yaw=-15"))
        XCTAssertEqual(app.buttons["projection-equirectangular180"].value as? String,"已選取")
        XCTAssertEqual(app.buttons["layout-sideBySide"].value as? String,"已選取")
        XCTAssertFalse(app.buttons["clearVRFormat"].isEnabled)
        app.buttons["immersiveStop"].tap()
        let file=app.buttons["entry-控制器互動測試.mp4"];XCTAssertTrue(file.waitForExistence(timeout:10));file.tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:20));app.buttons["immersiveSettings"].tap()
        XCTAssertEqual(app.buttons["projection-equirectangular180"].value as? String,"已選取")
        XCTAssertEqual(app.buttons["layout-sideBySide"].value as? String,"已選取")
        XCTAssertFalse(app.buttons["clearVRFormat"].isEnabled)
        app.buttons["immersiveStop"].tap()
    }
    @MainActor func testProjectionExplanationSpaceDoesNotJump() throws {
        for large in [false,true] {
            let app=XCUIApplication();app.launchArguments=["--controller-layout-review"]+(large ? ["--review-large-text"]:[]);app.launch()
            let target=app.buttons["recenterVideo"]
            XCTAssertTrue(target.waitForExistence(timeout:10))
            XCTAssertFalse(app.buttons["playbackDiagnostics"].exists)
            XCTAssertFalse(app.staticTexts["systemVideoCandidate"].exists)
            XCTAssertFalse(app.staticTexts["playbackDiagnosticsResult"].exists)
            let baseline=target.frame.minY
            for mode in ["equidistantFisheye180","equirectangular360","equirectangular180"] {
                let button=app.buttons["projection-"+mode];XCTAssertTrue(button.waitForExistence(timeout:5));button.tap()
                XCTAssertEqual(target.frame.minY,baseline,accuracy:2)
                let explanation=app.staticTexts["fisheyeScope"]
                XCTAssertEqual(explanation.exists,mode == "equidistantFisheye180")
                if explanation.exists {XCTAssertGreaterThan(explanation.frame.height,20);XCTAssertLessThanOrEqual(explanation.frame.maxY,target.frame.minY)}
            }
            app.terminate()
        }
    }
    @MainActor func testControllerFormatBubblesSelectAndPersist() throws {
        let app=openSystemFixture()
        let groups=[["projection-equirectangular180","projection-equirectangular360","projection-equidistantFisheye180"],["layout-overUnder","layout-sideBySide","layout-mono"]]
        for ids in groups {
            for id in ids {
                let button=app.buttons[id];XCTAssertTrue(button.waitForExistence(timeout:5))
                for peer in ids {XCTAssertEqual(app.buttons[peer].frame.midY,button.frame.midY,accuracy:3)}
                XCTAssertGreaterThanOrEqual(button.frame.height,40)
                button.tap()
                XCTAssertFalse(app.switches["swapVREyes"].exists)
                for peer in ids {XCTAssertEqual(app.buttons[peer].value as? String,peer == id ? "已選取":"未選取")}
            }
        }
        XCTAssertFalse(app.switches["swapVREyes"].exists)
        app.buttons["immersiveStop"].tap()
        let file=app.buttons["entry-控制器互動測試.mp4"];XCTAssertTrue(file.waitForExistence(timeout:10));file.tap()
        XCTAssertTrue(app.buttons["immersiveSettings"].waitForExistence(timeout:20));app.buttons["immersiveSettings"].tap()
        XCTAssertEqual(app.buttons["projection-equidistantFisheye180"].value as? String,"已選取")
        XCTAssertEqual(app.buttons["layout-mono"].value as? String,"已選取")
        app.buttons["immersiveStop"].tap()
    }
    @MainActor func testDirectionPadKeepsResetSemantics() throws {
        let app=openSystemFixture(),zero=app.buttons["directionZero"]
        XCTAssertTrue(zero.waitForExistence(timeout:5))
        XCTAssertEqual(zero.value as? String,"yaw=0,pitch=0,roll=0")
        app.buttons["directionLeft"].tap();XCTAssertEqual(zero.value as? String,"yaw=-15,pitch=0,roll=0")
        app.buttons["directionUp"].tap();XCTAssertEqual(zero.value as? String,"yaw=-15,pitch=15,roll=0")
        app.buttons["directionRight"].tap();app.buttons["directionDown"].tap()
        XCTAssertEqual(zero.value as? String,"yaw=0,pitch=0,roll=0")
        app.buttons["directionRight"].tap();zero.tap()
        XCTAssertEqual(zero.value as? String,"yaw=0,pitch=0,roll=0")
        XCTAssertTrue(app.buttons["recenterVideo"].exists)
        XCTAssertLessThan(app.buttons["recenterVideo"].frame.midY,app.buttons["directionUp"].frame.midY)
        XCTAssertGreaterThan(app.buttons["resetControllerPosition"].frame.midY,app.buttons["directionDown"].frame.midY)
        XCTAssertEqual(app.buttons["recenterVideo"].frame.midX,zero.frame.midX,accuracy:3)
        XCTAssertEqual(app.buttons["resetControllerPosition"].frame.midX,zero.frame.midX,accuracy:3)
        XCTAssertEqual(app.buttons["recenterVideo"].frame.width,app.buttons["resetControllerPosition"].frame.width,accuracy:3)
        XCTAssertTrue(app.buttons["resetControllerPosition"].exists)
        XCTAssertLessThan(app.buttons["directionUp"].frame.midY,zero.frame.midY)
        XCTAssertGreaterThan(app.buttons["directionDown"].frame.midY,zero.frame.midY)
        XCTAssertLessThan(app.buttons["directionLeft"].frame.midX,zero.frame.midX)
        XCTAssertGreaterThan(app.buttons["directionRight"].frame.midX,zero.frame.midX)
        app.buttons["immersiveStop"].tap()
    }
    @MainActor func testImmersiveBackgroundSingleAndDoubleTap() throws {
        guard ProcessInfo.processInfo.environment["VISTA_IMMERSIVE_COORDINATE_TEST"] == "1" else {
            throw XCTSkip("Opt-in: visionOS simulator XCTest background coordinates currently fail with invalid scene ID; not validated.")
        }
        let app=openPreparationFixture("--slow-media-preparation")
        let stop=app.buttons["immersiveStop"]
        XCTAssertTrue(stop.waitForExistence(timeout:15))
        let background=app.coordinate(withNormalizedOffset:CGVector(dx:0.05,dy:0.05))
        background.tap()
        XCTAssertTrue(NSPredicate(format:"exists == false").evaluate(with:stop) || XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:stop)],timeout:3) == .completed)
        background.doubleTap()
        XCTAssertTrue(stop.waitForExistence(timeout:5))
        app.buttons["immersiveSettings"].tap()
        XCTAssertTrue(app.staticTexts["resetControllerGestureHint"].waitForExistence(timeout:5))
        app.buttons["resetControllerPosition"].tap()
        XCTAssertTrue(stop.exists)
        stop.tap()
        XCTAssertTrue(app.buttons["entry-H264 播放測試.mp4"].waitForExistence(timeout:10))
    }
    @MainActor func testFixedHeadersAndDisplayWindowRestoration() throws {
        let app=fresh()
        app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-大量影片"].waitForExistence(timeout:10))
        app.buttons["entry-大量影片"].tap();XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].waitForExistence(timeout:10));app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        let header=app.buttons["sort-name"],scroll=app.scrollViews["directoryScroll"]
        XCTAssertTrue(header.waitForExistence(timeout:10))
        let y=header.frame.minY
        scroll.swipeUp();scroll.swipeUp()
        XCTAssertTrue(header.isHittable);XCTAssertEqual(header.frame.minY,y,accuracy:2)
        app.buttons["sort-modified"].tap();app.buttons["sort-modified"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleSize"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleCreated"].tap()
        app.terminate()
        app.launchArguments=["--shortcut-ui-tests","--window-resize-test","--persist-display-test"];app.launch()
        XCTAssertTrue(app.buttons["testWideWindow"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["sort-modified"].value as? String,"降冪")
        XCTAssertFalse(app.buttons["sort-size"].exists);XCTAssertTrue(app.buttons["sort-created"].exists)
        app.buttons["testWideWindow"].tap()
        let wide=scroll.frame.width
        XCTAssertGreaterThan(wide,1000)
        app.terminate();app.launch()
        XCTAssertTrue(scroll.waitForExistence(timeout:10))
        print("RESTORED_WINDOW_LIST_WIDTH",wide,scroll.frame.width)
        XCTAssertEqual(scroll.frame.width,wide,accuracy:3)
        XCTAssertEqual(app.buttons["sort-modified"].value as? String,"降冪")
        XCTAssertFalse(app.buttons["sort-size"].exists);XCTAssertTrue(app.buttons["sort-created"].exists)
    }
    @MainActor func testParentColumnContainsOnlyFolders() throws {
        let app=fresh()
        app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        app.buttons["entry-影片"].tap();app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["entry-電影"].tap()
        XCTAssertTrue(app.buttons["entry-預告片.mp4"].waitForExistence(timeout:10))
        app.buttons["entry-科幻"].tap()
        XCTAssertTrue(app.buttons["parent-紀錄片"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["parent-預告片.mp4"].exists)
        XCTAssertTrue(app.buttons["entry-星際漫遊_SBS_180.mp4"].exists)
        app.buttons["parent-紀錄片"].tap()
        XCTAssertEqual(app.staticTexts["prototypePath"].label,"/影片/電影/紀錄片")
        app.buttons["parent-科幻"].tap();app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["entry-預告片.mp4"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["entry-科幻"].isHittable)
    }
    @MainActor func testOptionalHeaderTitlesAndArrowsCentered() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--window-resize-test"];app.launch()
        XCTAssertTrue(app.buttons["testWideWindow"].waitForExistence(timeout:10));app.buttons["testWideWindow"].tap()
        for id in ["toggleModified","toggleCreated","toggleSize"] {
            app.buttons["columnOptions"].tap();app.buttons[id].tap()
        }
        func centered(_ field:String) {
            let button=app.buttons["sort-"+field]
            button.tap()
            for _ in 0..<2 {
                let title=app.staticTexts["column-title-"+field],arrow=app.images["column-arrow-"+field]
                XCTAssertTrue(title.exists);XCTAssertTrue(arrow.exists)
                let group=title.frame.union(arrow.frame)
                XCTAssertEqual(group.midX,button.frame.midX,accuracy:2,field)
                button.tap()
            }
        }
        for field in ["modified","created","size","tags"] {centered(field)}
        app.buttons["columnOptions"].tap();app.buttons["fitColumns"].tap()
        for field in ["modified","created","size","tags"] {centered(field)}
        app.buttons["columnOptions"].tap();app.buttons["resetColumns"].tap()
        app.buttons["testNarrowWindow"].tap();centered("modified")
    }
    @MainActor func testColumnHeaderContentAlignmentAfterFitAndReset() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--window-resize-test","--muted-blue-preview"];app.launch()
        XCTAssertTrue(app.buttons["testWideWindow"].waitForExistence(timeout:10));app.buttons["testWideWindow"].tap()
        let header=app.buttons["sort-modified"],cell=app.staticTexts["modified-星際漫遊_SBS_180.mp4"]
        XCTAssertTrue(cell.waitForExistence(timeout:10))
        func aligned(_ stage:String) {
            XCTAssertEqual(app.buttons["sort-name"].frame.minX,app.buttons["entry-星際漫遊_SBS_180.mp4"].frame.minX,accuracy:2,stage+" bubble left")
            // SwiftUI merges the sole title into its button when the sort arrow disappears.
            if app.staticTexts["column-title-name"].exists {
                XCTAssertEqual(app.staticTexts["column-title-name"].frame.minX,app.staticTexts["entry-name-星際漫遊_SBS_180.mp4"].frame.minX,accuracy:2,stage+" text left")
            }
            print("COLUMN_ALIGNMENT",stage,header.frame.minX,cell.frame.minX)
            XCTAssertEqual(header.frame.minX,cell.frame.minX,accuracy:2,stage)
            let sizeHeader=app.buttons["sort-size"],sizeCell=app.staticTexts["size-星際漫遊_SBS_180.mp4"]
            XCTAssertEqual(sizeHeader.frame.maxX-12,sizeCell.frame.maxX,accuracy:2,stage+" size right inset")
        }
        for field in ["name","modified","size"] {
            let sort=app.buttons["sort-"+field]
            let grip=app.descendants(matching:.any).matching(identifier:"resize-"+field).firstMatch
            XCTAssertEqual(sort.frame.height,grip.frame.height,accuracy:2,"header/grip height "+field)
        }
        aligned("initial")
        XCTAssertEqual(app.staticTexts["size-星際漫遊_SBS_180.mp4"].label,"1.0 MB")
        app.buttons["columnOptions"].tap();app.buttons["fitColumns"].tap();aligned("fit")
        app.buttons["columnOptions"].tap();app.buttons["resetColumns"].tap();aligned("reset")
        let handle=app.descendants(matching:.any).matching(identifier:"resize-name").firstMatch
        handle.press(forDuration:0.8,thenDragTo:header);aligned("drag")
        app.buttons["sort-modified"].tap();aligned("sort")
        app.buttons["sort-size"].tap()
        XCTAssertEqual(app.buttons["sort-size"].value as? String,"升冪");aligned("size ascending")
        app.buttons["sort-size"].tap()
        XCTAssertEqual(app.buttons["sort-size"].value as? String,"降冪");aligned("size descending")
        app.buttons["columnOptions"].tap();app.buttons["fitColumns"].tap()
        app.descendants(matching:.any).matching(identifier:"resize-size").firstMatch.doubleTap()
        aligned("size fit")
        app.buttons["testNarrowWindow"].tap();app.buttons["sort-name"].tap();aligned("narrow")
    }
    @MainActor func testAutomaticOnlyTagsLegacySettingsAndSortFallback() throws {
        let app=XCUIApplication()
        app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--host-navigation-fixture","--legacy-tag-mac","--legacy-tag-preferences"];app.launch()
        app.buttons["emptyEdit"].tap();app.buttons["savedSMBSource"].tap()
        XCTAssertTrue(app.buttons["entry-Videos"].waitForExistence(timeout:10));app.buttons["entry-Videos"].tap()
        app.buttons["entry-影片"].tap();app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["sort-tags"].exists)
        XCTAssertEqual(app.buttons["sort-name"].value as? String,"升冪")
        app.buttons["columnOptions"].tap();XCTAssertFalse(app.buttons["toggleTags"].exists);app.buttons["resetColumns"].tap()
        app.buttons["editShortcuts"].tap();app.buttons["sourceSettings-測試分享"].tap()
        XCTAssertFalse(app.switches["manualTagSupport"].exists)
        XCTAssertFalse(app.buttons["resetTagSupport"].exists)
        app.buttons["prototypeConnect"].tap();app.buttons["editShortcuts"].tap()
        app.terminate()
        app.launchArguments=["--shortcut-ui-tests","--host-navigation-fixture","--persist-display-test","--tag-capability-positive"];app.launch()
        XCTAssertTrue(app.buttons["sort-tags"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"降冪")
        app.terminate()
        app.launchArguments=["--shortcut-ui-tests","--host-navigation-fixture","--persist-display-test"];app.launch()
        XCTAssertTrue(app.buttons["sort-tags"].waitForExistence(timeout:10))
    }
    @MainActor func testAutomaticPositiveCapabilitySurvivesRelaunch() throws {
        let app=XCUIApplication()
        app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--host-navigation-fixture","--tag-capability-positive"];app.launch()
        app.buttons["emptyEdit"].tap();app.buttons["savedSMBSource"].tap()
        XCTAssertTrue(app.buttons["entry-Videos"].waitForExistence(timeout:10));app.buttons["entry-Videos"].tap()
        app.buttons["entry-影片"].tap();app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["columnOptions"].tap();XCTAssertTrue(app.buttons["toggleTags"].waitForExistence(timeout:5))
        app.terminate()
        app.launchArguments=["--shortcut-ui-tests","--host-navigation-fixture"];app.launch()
        XCTAssertTrue(app.buttons["columnOptions"].waitForExistence(timeout:10));app.buttons["columnOptions"].tap()
        XCTAssertTrue(app.buttons["toggleTags"].exists)
    }
    @MainActor func testDirectoryRefreshReplacesSnapshotAndPreservesSort() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--refresh-directory-fixture"];app.launch()
        XCTAssertTrue(app.buttons["entry-舊檔.mp4"].waitForExistence(timeout:10))
        app.buttons["sort-size"].tap()
        app.buttons["columnOptions"].tap();XCTAssertFalse(app.buttons["refreshTags"].exists);app.buttons["refreshDirectory"].tap()
        XCTAssertTrue(app.buttons["entry-新檔.mp4"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["entry-舊檔.mp4"].exists)
        XCTAssertEqual(app.buttons["sort-size"].value as? String,"升冪")
        XCTAssertLessThan(app.buttons["entry-保留.mp4"].frame.minY,app.buttons["entry-新檔.mp4"].frame.minY)
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        app.buttons["editShortcuts"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertFalse(app.buttons["sort-size"].exists)
    }
    @MainActor func testDirectoryRefreshFailureCanRetry() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--refresh-directory-fixture","--refresh-failure-fixture"];app.launch()
        XCTAssertTrue(app.buttons["entry-舊檔.mp4"].waitForExistence(timeout:10))
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        XCTAssertTrue(app.staticTexts["listingError"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["entry-舊檔.mp4"].exists)
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        XCTAssertTrue(app.buttons["entry-新檔.mp4"].waitForExistence(timeout:10))
    }
    @MainActor func testRefreshReadsTagsAndPreservesDescendingSort() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--full-tags-fixture","--refresh-directory-fixture"];app.launch()
        waitForTags(app,count:2)
        XCTAssertFalse(app.staticTexts["瀏覽介面原型"].exists)
        app.buttons["sort-tags"].tap();app.buttons["sort-tags"].tap()
        waitForTags(app,count:2)
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        XCTAssertTrue(app.buttons["entry-新檔.mp4"].waitForExistence(timeout:10))
        waitForTags(app,count:2)
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"降冪")
        XCTAssertLessThan(app.buttons["entry-新檔.mp4"].frame.minY,app.buttons["entry-保留.mp4"].frame.minY)
        XCTAssertFalse(app.buttons["entry-舊檔.mp4"].exists)
        app.buttons["columnOptions"].tap();app.buttons["toggleTags"].tap()
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        XCTAssertTrue(app.buttons["entry-新檔.mp4"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["sort-tags"].exists)
    }
    @MainActor func testColumnSortingVisibilityAndNavigation() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5));app.buttons["entry-影片"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["sort-modified"].waitForExistence(timeout:5))
        app.buttons["sort-modified"].tap()
        XCTAssertTrue(app.buttons["entry-電影"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["entry-電影"].frame.minY,app.buttons["entry-旅行"].frame.minY)
        app.buttons["sort-modified"].tap()
        XCTAssertTrue(app.buttons["entry-旅行"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["entry-旅行"].frame.minY,app.buttons["entry-電影"].frame.minY)
        app.buttons["entry-電影"].tap()
        XCTAssertTrue(app.buttons["entry-科幻"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons["sort-modified"].value as? String,"降冪")
        app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["entry-旅行"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["entry-旅行"].frame.minY,app.buttons["entry-電影"].frame.minY)
        app.buttons["columnOptions"].tap();app.buttons["toggleSize"].tap()
        XCTAssertFalse(app.buttons["sort-size"].exists)
        app.buttons["columnOptions"].tap();app.buttons["toggleSize"].tap()
        XCTAssertTrue(app.buttons["sort-size"].exists)
        app.buttons["sort-size"].tap();app.buttons["sort-size"].tap()
        XCTAssertEqual(app.buttons["sort-size"].value as? String,"降冪")
    }
    @MainActor func testNarrowColumnsDoNotScrollHorizontally() throws {
        let app=fresh(narrow:true);app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5));app.buttons["entry-影片"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        let scroll=app.scrollViews["directoryScroll"],name=app.buttons["sort-name"]
        XCTAssertTrue(scroll.waitForExistence(timeout:5));XCTAssertLessThanOrEqual(scroll.frame.width,441)
        let x=name.frame.minX;scroll.swipeLeft();XCTAssertEqual(name.frame.minX,x,accuracy:2)
        app.buttons["sort-modified"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleModified"].tap()
        XCTAssertFalse(app.buttons["sort-modified"].exists)
        XCTAssertEqual(name.value as? String,"升冪")
        XCTAssertTrue(app.buttons["entry-電影"].isHittable)
    }
    @MainActor func testCreationColumnAndTopAlignedSmallEmptyLists() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5));app.buttons["entry-影片"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["entry-電影"].waitForExistence(timeout:5))
        let scroll=app.scrollViews["directoryScroll"]
        XCTAssertLessThan(app.buttons["entry-電影"].frame.minY-app.buttons["sort-name"].frame.maxY,80)
        app.buttons["columnOptions"].tap();app.buttons["toggleModified"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleSize"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleCreated"].tap()
        XCTAssertTrue(app.buttons["sort-created"].isHittable)
        app.buttons["sort-created"].tap()
        XCTAssertTrue(app.buttons["entry-旅行"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["entry-旅行"].frame.minY,app.buttons["entry-電影"].frame.minY)
        app.buttons["sort-created"].tap();XCTAssertEqual(app.buttons["sort-created"].value as? String,"降冪")
        app.buttons["columnOptions"].tap();app.buttons["toggleCreated"].tap()
        XCTAssertFalse(app.buttons["sort-created"].exists)
        app.buttons["editShortcuts"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-空資料夾"].waitForExistence(timeout:5));app.buttons["entry-空資料夾"].tap()
        XCTAssertTrue(app.staticTexts["空資料夾"].firstMatch.waitForExistence(timeout:5))
        let empty=app.staticTexts["emptyDirectoryLabel"]
        XCTAssertTrue(empty.waitForExistence(timeout:5));XCTAssertLessThan(empty.frame.minY-scroll.frame.minY,140)
    }
    @MainActor func testAllColumnsCompactLayoutAndSorting() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--window-resize-test","--muted-blue-preview"];app.launch()
        XCTAssertTrue(app.buttons["testWideWindow"].waitForExistence(timeout:10));app.buttons["testWideWindow"].tap()
        let scroll=app.scrollViews["directoryScroll"]
        XCTAssertTrue(app.buttons["entry-星際漫遊_SBS_180.mp4"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["sort-size"].isHittable)
        app.buttons["sort-created"].tap();app.buttons["sort-created"].tap()
        XCTAssertEqual(app.buttons["sort-created"].value as? String,"降冪")
        app.buttons["columnOptions"].tap();app.buttons["toggleModified"].tap()
        XCTAssertFalse(app.buttons["sort-modified"].exists)
        app.buttons["testNarrowWindow"].tap()
        let x=app.buttons["sort-name"].frame.minX
        scroll.swipeLeft();XCTAssertEqual(app.buttons["sort-name"].frame.minX,x,accuracy:2)
    }
    @MainActor func testColumnResizeDragDoubleTapMenuAndReset() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview"];app.launch()
        let handle=app.descendants(matching:.any).matching(identifier:"resize-name").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout:10))
        let original=Int(handle.value as? String ?? "")!
        handle.press(forDuration:0.8,thenDragTo:app.buttons["sort-modified"])
        let dragged=Int(handle.value as? String ?? "")!
        print("WIDTH_VALUES",original,dragged)
        XCTAssertGreaterThan(dragged,original+35)
        handle.doubleTap()
        let fitted=Int(handle.value as? String ?? "")!
        print("FIT_VALUE",fitted)
        XCTAssertGreaterThanOrEqual(fitted,160);XCTAssertLessThanOrEqual(fitted,600)
        app.buttons["columnOptions"].tap();app.buttons["resetColumns"].tap()
        XCTAssertEqual(Int(handle.value as? String ?? ""),original)
        app.buttons["columnOptions"].tap();app.buttons["fitColumns"].tap()
        XCTAssertEqual(Int(handle.value as? String ?? ""),fitted)
        app.buttons["sort-name"].tap();XCTAssertEqual(app.buttons["sort-name"].value as? String,"降冪")
        app.buttons["columnOptions"].tap();app.buttons["resetColumns"].tap()
        XCTAssertEqual(Int(handle.value as? String ?? ""),original)
    }
    @MainActor func testBrowserHeaderUsesSavedHostName() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--source-shortcut-fixture","--host-navigation-fixture"];app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        app.buttons["savedSMBSource"].tap()
        XCTAssertTrue(app.buttons["entry-Videos"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["browserSourceName"].label,"測試分享")
        app.buttons["entry-Videos"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["prototypePath"].label,"/Videos")
        XCTAssertEqual(app.staticTexts["browserSourceName"].label,"測試分享")
    }
    @MainActor func testVerticalOnlyAndRealWindowResizePreservesColumnWidth() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--window-resize-test","--muted-blue-preview"];app.launch()
        XCTAssertTrue(app.buttons["testNarrowWindow"].waitForExistence(timeout:10));app.buttons["testNarrowWindow"].tap()
        let scroll=app.scrollViews["directoryScroll"],name=app.buttons["sort-name"]
        let narrowWidth=scroll.frame.width,startX=name.frame.minX
        scroll.swipeLeft();XCTAssertEqual(name.frame.minX,startX,accuracy:2)
        let handle=app.descendants(matching:.any).matching(identifier:"resize-name").firstMatch
        handle.press(forDuration:0.8,thenDragTo:app.buttons["sort-modified"])
        let custom=Int(handle.value as? String ?? "")!
        XCTAssertGreaterThan(custom,200)
        app.buttons["testWideWindow"].tap()
        XCTAssertGreaterThan(scroll.frame.width,narrowWidth+200)
        XCTAssertEqual(Int(handle.value as? String ?? ""),custom)
        XCTAssertTrue(app.buttons["sort-size"].isHittable)
        app.buttons["sort-size"].tap();XCTAssertEqual(app.buttons["sort-size"].value as? String,"升冪")
        app.buttons["testNarrowWindow"].tap()
        XCTAssertEqual(Int(handle.value as? String ?? ""),custom)
        let currentX=name.frame.minX;scroll.swipeLeft();XCTAssertEqual(name.frame.minX,currentX,accuracy:2)
        app.buttons["columnOptions"].tap();app.buttons["fitColumns"].tap()
        let afterFit=Int(handle.value as? String ?? "")!
        app.buttons["testWideWindow"].tap();XCTAssertEqual(Int(handle.value as? String ?? ""),afterFit)
        app.buttons["columnOptions"].tap();app.buttons["resetColumns"].tap()
    }
    @MainActor func testVerticalScrollingStillLoadsLargeDirectory() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-大量影片"].waitForExistence(timeout:5));app.buttons["entry-大量影片"].tap()
        XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].waitForExistence(timeout:10));app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        let first=app.buttons["entry-影片 0001.mp4"],scroll=app.scrollViews["directoryScroll"]
        XCTAssertTrue(first.waitForExistence(timeout:10));let oldY=first.frame.minY
        scroll.swipeUp()
        XCTAssertTrue(!first.isHittable || first.frame.minY < oldY-20)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","entry-影片")).count>0)
    }
    @MainActor func testShortcutPressAndEdgeAutoscroll() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--long-shortcuts"];app.launch()
        let grip=app.images["drag-Folder 01"]
        XCTAssertTrue(grip.waitForExistence(timeout:10));grip.press(forDuration:0.4)
        XCTAssertTrue((grip.value as? String ?? "").contains("未按住；已收到按住"))
        let state=app.staticTexts["shortcutDragTestState"]
        grip.press(forDuration:0.4,thenDragTo:app.staticTexts["shortcutBottomEdge"],withVelocity:.slow,thenHoldForDuration:35)
        print("EDGE DOWN",state.label)
        XCTAssertTrue(state.label.contains("drop=39;active=false"));XCTAssertTrue(state.label.hasSuffix("Folder 01"))
        XCTAssertFalse(app.descendants(matching:.any)["shortcutInsertionIndicator"].exists)
        let moved=app.images["drag-Folder 01"];XCTAssertTrue(moved.isHittable)
        moved.press(forDuration:0.4,thenDragTo:app.staticTexts["shortcutTopEdge"],withVelocity:.slow,thenHoldForDuration:35)
        print("EDGE UP",state.label)
        XCTAssertTrue(state.label.contains("active=false"))
        XCTAssertTrue(app.images["drag-Folder 02"].isHittable) // Top edge is above shortcut section: scroll, then cancel rather than reorder sources.
        XCTAssertFalse(app.descendants(matching:.any)["shortcutInsertionIndicator"].exists)
    }
    @MainActor func testShortcutThreeItemInsertionAndCancel() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        app.buttons["entry-影片"].tap();app.buttons["addShortcut"].tap()
        app.buttons["entry-電影"].tap();app.buttons["addShortcut"].tap()
        app.buttons["entry-科幻"].tap();app.buttons["addShortcut"].tap()
        func expectOrder(_ names:[String],file:StaticString=#filePath,line:UInt=#line) {
            let actual=names.sorted{app.descendants(matching:.any).matching(identifier:"rename-\($0)").firstMatch.frame.minY < app.descendants(matching:.any).matching(identifier:"rename-\($1)").firstMatch.frame.minY}
            XCTAssertEqual(actual,names,file:file,line:line)
            XCTAssertFalse(app.descendants(matching:.any)["shortcutInsertionIndicator"].exists,file:file,line:line)
        }
        app.images["drag-影片"].press(forDuration:0.8,thenDragTo:app.staticTexts["drop-after-科幻"])
        expectOrder(["電影","科幻","影片"])
        app.images["drag-影片"].press(forDuration:0.8,thenDragTo:app.staticTexts["drop-after-電影"])
        expectOrder(["電影","影片","科幻"])
        app.images["drag-科幻"].press(forDuration:0.8,thenDragTo:app.staticTexts["drop-before-電影"])
        expectOrder(["科幻","電影","影片"])
        app.images["drag-科幻"].press(forDuration:0.8,thenDragTo:app.staticTexts["folderTitle"])
        expectOrder(["科幻","電影","影片"])
        app.buttons["editShortcuts"].tap();app.terminate();app.launchArguments=["--shortcut-ui-tests"];app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        expectOrder(["科幻","電影","影片"])
    }
    @MainActor func testModesPersistenceAndShortcutEditing() throws {
        let app=fresh()
        XCTAssertFalse(app.buttons["localDemoSource"].exists)
        XCTAssertFalse(app.buttons["connectSMB"].exists)
        app.buttons["emptyEdit"].tap()
        app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5));app.buttons["entry-影片"].tap()
        XCTAssertTrue(app.buttons["addShortcut"].waitForExistence(timeout:5));app.buttons["addShortcut"].tap()
        XCTAssertFalse(app.buttons["addShortcut"].isEnabled)
        XCTAssertFalse(app.buttons["shortcut-影片"].exists)
        app.buttons["entry-電影"].tap();app.buttons["addShortcut"].tap()
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"電影")
        let rename=app.descendants(matching:.any).matching(identifier:"rename-影片").firstMatch
        XCTAssertTrue(rename.exists);rename.tap();rename.typeText("暫存")
        XCTAssertTrue(app.buttons["cancelShortcutName"].exists)
        XCTAssertEqual(app.buttons["cancelShortcutName"].frame.height,app.buttons["remove-影片暫存"].frame.height,accuracy:2)
        XCTAssertEqual(app.buttons["cancelShortcutName"].frame.width,app.buttons["remove-影片暫存"].frame.width,accuracy:2)
        app.buttons["cancelShortcutName"].tap()
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"rename-影片").firstMatch.value as? String,"影片")
        XCTAssertFalse(app.buttons["cancelShortcutName"].exists)
        app.descendants(matching:.any).matching(identifier:"rename-影片").firstMatch.tap();app.descendants(matching:.any).matching(identifier:"rename-影片").firstMatch.typeText("收藏\n")
        XCTAssertFalse(app.buttons["cancelShortcutName"].exists)
        let renamed=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","rename-")).allElementsBoundByIndex.map {$0.value as? String ?? ""}.first {$0.contains("收藏")}!
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"電影")
        app.images["drag-電影"].press(forDuration:0.8,thenDragTo:app.staticTexts["drop-before-\(renamed)"])
        XCTAssertLessThan(app.descendants(matching:.any).matching(identifier:"rename-電影").firstMatch.frame.minY,app.descendants(matching:.any).matching(identifier:"rename-\(renamed)").firstMatch.frame.minY)
        XCTAssertFalse(app.otherElements["shortcutInsertionIndicator"].exists)
        let movieGrip=app.images["drag-電影"]
        movieGrip.press(forDuration:0.8,thenDragTo:app.staticTexts["drop-after-\(renamed)"])
        XCTAssertGreaterThan(app.descendants(matching:.any).matching(identifier:"rename-電影").firstMatch.frame.minY,app.descendants(matching:.any).matching(identifier:"rename-\(renamed)").firstMatch.frame.minY)
        movieGrip.press(forDuration:0.8,thenDragTo:app.staticTexts["folderTitle"])
        XCTAssertGreaterThan(app.descendants(matching:.any).matching(identifier:"rename-電影").firstMatch.frame.minY,app.descendants(matching:.any).matching(identifier:"rename-\(renamed)").firstMatch.frame.minY)
        XCTAssertFalse(app.otherElements["shortcutInsertionIndicator"].exists)
        app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["localDemoSource"].exists)
        XCTAssertTrue(app.buttons["shortcut-電影"].exists)
        app.buttons["shortcut-\(renamed)"].tap()
        XCTAssertTrue(app.buttons["entry-電影"].waitForExistence(timeout:5))
        app.terminate();app.launchArguments=["--shortcut-ui-tests"];app.launch()
        XCTAssertTrue(app.buttons["shortcut-\(renamed)"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["entry-電影"].waitForExistence(timeout:5))
        app.buttons["editShortcuts"].tap();app.buttons["remove-\(renamed)"].tap()
        app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["shortcut-\(renamed)"].exists)
        XCTAssertTrue(app.buttons["shortcut-電影"].exists)
    }
    @MainActor func testParentColumnsHomeAndEditingRestore() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5));app.buttons["entry-影片"].tap()
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["shortcutHome"].exists)
        XCTAssertFalse(app.buttons["folderBack"].isEnabled)
        app.buttons["entry-電影"].tap()
        XCTAssertTrue(app.buttons["parent-電影"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["shortcut-影片"].exists)
        XCTAssertTrue(app.buttons["shortcutHome"].exists)
        app.buttons["entry-科幻"].tap()
        XCTAssertTrue(app.buttons["parent-科幻"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"科幻")
        app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["parent-電影"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"電影")
        XCTAssertFalse(app.buttons["editShortcuts"].exists)
        app.buttons["shortcutHome"].tap()
        XCTAssertTrue(app.buttons["editShortcuts"].exists)
        XCTAssertFalse(app.buttons["shortcutHome"].exists)
        app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["localDemoSource"].exists)
        app.buttons["entry-電影"].tap();app.buttons["entry-科幻"].tap()
        XCTAssertFalse(app.buttons["parent-科幻"].exists)
        XCTAssertFalse(app.buttons["shortcutHome"].exists)
        app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["shortcut-影片"].exists)
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"影片")
        app.buttons["entry-電影"].tap()
        XCTAssertTrue(app.buttons["parent-電影"].waitForExistence(timeout:5))
        app.buttons["parent-旅行"].tap()
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"旅行")
        app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["shortcut-影片"].exists)
        XCTAssertFalse(app.buttons["folderBack"].isEnabled)
    }
    @MainActor func testSourceRenameAccountFailureAndRemoval() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        XCTAssertFalse(app.buttons["sourceRemove-測試分享"].exists)
        app.buttons["sourceSettings-測試分享"].tap()
        XCTAssertLessThan(app.textFields["prototypeServer"].frame.minY,app.textFields["connectionName"].frame.minY)
        XCTAssertEqual(app.buttons["prototypeConnect"].frame.midY,app.buttons["sourceRemove-測試分享"].frame.midY,accuracy:2)
        XCTAssertFalse(app.switches["保存登入資訊"].exists)
        XCTAssertFalse(app.textFields["prototypeServer"].isEnabled)
        XCTAssertTrue(app.textFields["prototypeUsername"].isEnabled)
        let name=app.textFields["connectionName"];name.tap();name.typeText("新版")
        let newName=try XCTUnwrap(name.value as? String)
        app.buttons["prototypeConnect"].tap()
        XCTAssertTrue(app.buttons["sourceSettings-\(newName)"].exists)
        app.buttons["sourceSettings-\(newName)"].tap()
        let username=app.textFields["prototypeUsername"];username.tap();username.typeText("-changed")
        app.buttons["prototypeConnect"].tap()
        XCTAssertTrue(app.staticTexts["connectionError"].exists)
        XCTAssertTrue(app.buttons["fallbackAuthentication"].exists)
        app.buttons["fallbackAuthentication"].tap()
        XCTAssertTrue(app.textFields["fallbackShare"].exists)
        app.buttons["取消"].tap();app.buttons["sourceSettings-\(newName)"].tap()
        XCTAssertEqual(app.textFields["prototypeUsername"].value as? String,"original-user")
        app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["sourceRemove-\(newName)"].exists)
        app.buttons["sourceSettings-\(newName)"].tap()
        app.buttons["sourceRemove-\(newName)"].tap();app.buttons["cancelSourceRemoval"].tap()
        XCTAssertTrue(app.buttons["prototypeConnect"].exists)
        XCTAssertTrue(app.buttons["sourceSettings-\(newName)"].exists)
        app.buttons["sourceRemove-\(newName)"].tap();app.buttons["confirmSourceRemoval"].tap()
        XCTAssertTrue(app.buttons["sourceSettings-\(newName)"].waitForNonExistence(timeout:5))
        app.terminate();app.launchArguments=["--shortcut-ui-tests","--source-settings-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        XCTAssertTrue(app.buttons["sourceSettings-\(newName)"].waitForNonExistence(timeout:5))
    }
    @MainActor func testSourceRemovalListsShortcutsAndCancellationIsNonDestructive() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--source-shortcut-fixture"];app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        app.buttons["sourceSettings-測試分享"].tap();app.buttons["sourceRemove-測試分享"].tap()
        XCTAssertTrue(app.staticTexts["affectedShortcut-保留的捷徑"].exists)
        XCTAssertTrue(app.staticTexts["affectedShortcut-分享根捷徑"].exists)
        XCTAssertFalse(app.staticTexts["affectedShortcut-其他主機外的捷徑"].exists)
        XCTAssertEqual(app.buttons["confirmSourceRemoval"].label,"一併移除")
        app.buttons["cancelSourceRemoval"].tap()
        XCTAssertTrue(app.buttons["prototypeConnect"].exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"rename-保留的捷徑").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"rename-分享根捷徑").firstMatch.exists)
        XCTAssertTrue(app.buttons["sourceSettings-測試分享"].exists)
        app.terminate();app.launchArguments=["--shortcut-ui-tests","--source-settings-fixture"];app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"rename-保留的捷徑").firstMatch.exists)
        app.buttons["sourceSettings-測試分享"].tap();app.buttons["sourceRemove-測試分享"].tap();app.buttons["confirmSourceRemoval"].tap()
        XCTAssertTrue(app.buttons["sourceSettings-測試分享"].waitForNonExistence(timeout:5))
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"rename-保留的捷徑").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"rename-分享根捷徑").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"rename-其他主機外的捷徑").firstMatch.exists)
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["sourceSettings-測試分享"].exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"rename-保留的捷徑").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"rename-其他主機外的捷徑").firstMatch.exists)
    }
    @MainActor func testSyntheticDiscoveryFillsHostNameAndFocusesUsername() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--network-discovery-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap();app.buttons["connectSMB"].tap()
        app.buttons["browseNetwork"].tap()
        XCTAssertTrue(app.buttons["discovered-測試 NAS"].waitForExistence(timeout:5));app.buttons["discovered-測試 NAS"].tap()
        XCTAssertEqual(app.textFields["prototypeServer"].value as? String,"test-nas.example.test")
        XCTAssertEqual(app.textFields["connectionName"].value as? String,"測試 NAS")
        app.typeText("fixture-user")
        XCTAssertEqual(app.textFields["prototypeUsername"].value as? String,"fixture-user")
        XCTAssertFalse(app.switches["保存登入資訊"].exists)
    }
    @MainActor func testHostShareRootShortcutsAndNavigation() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--host-navigation-fixture"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap()
        app.buttons["savedSMBSource"].tap()
        XCTAssertTrue(app.buttons["entry-Videos"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["addShortcut"].exists)
        app.buttons["entry-Videos"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        app.buttons["addShortcut"].tap();app.buttons["entry-影片"].tap()
        app.buttons["addShortcut"].tap();app.buttons["folderBack"].tap();app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["entry-Movies"].waitForExistence(timeout:5))
        app.buttons["editShortcuts"].tap()
        app.buttons["shortcut-Videos"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["folderBack"].isEnabled)
        app.buttons["entry-影片"].tap()
        XCTAssertTrue(app.buttons["parent-影片"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["editShortcuts"].exists)
        app.buttons["shortcutHome"].tap()
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"Videos")
        XCTAssertTrue(app.buttons["editShortcuts"].exists)
    }
    @MainActor func testHostEnumerationFailureAllowsManualShare() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--source-settings-fixture","--host-navigation-fixture","--host-list-error"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap();app.buttons["savedSMBSource"].tap()
        XCTAssertTrue(app.staticTexts["listingError"].waitForExistence(timeout:5))
        app.textFields["manualShare"].tap();app.textFields["manualShare"].typeText("Known")
        app.buttons["openManualShare"].tap()
        XCTAssertTrue(app.buttons["entry-影片"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["folderTitle"].label,"Known")
        app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        XCTAssertTrue(app.buttons["shortcut-Known"].exists)
    }
    @MainActor func testDiscoveryRetainsDisabledStaleResultsWithoutSearchingText() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--network-discovery-fixture","--discovery-many","--discovery-stale","--narrow-form"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap();app.buttons["connectSMB"].tap()
        XCTAssertFalse(app.textFields["prototypeShare"].exists)
        app.buttons["browseNetwork"].tap()
        let first=app.buttons["discovered-測試 NAS"],last=app.buttons["discovered-範例伺服器 8"]
        XCTAssertTrue(first.waitForExistence(timeout:5));XCTAssertGreaterThan(last.frame.minY,first.frame.minY)
        XCTAssertFalse(app.staticTexts["discoveryStatus"].exists)
        app.buttons["browseNetwork"].tap();app.buttons["browseNetwork"].tap()
        XCTAssertTrue(first.exists);XCTAssertFalse(first.isEnabled)
        XCTAssertTrue(app.staticTexts["staleDiscovery"].exists)
        XCTAssertFalse(app.staticTexts["discoveryStatus"].exists)
    }
    @MainActor func testEmptyDiscoveryStatusIsNotAButton() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--reset-shortcut-fixture","--network-discovery-fixture","--discovery-empty"];app.launch()
        XCTAssertTrue(app.buttons["emptyEdit"].waitForExistence(timeout:10));app.buttons["emptyEdit"].tap();app.buttons["connectSMB"].tap();app.buttons["browseNetwork"].tap()
        XCTAssertTrue(app.staticTexts["discoveryStatus"].exists)
        XCTAssertFalse(app.buttons["discoveryStatus"].exists)
        app.buttons["browseNetwork"].tap()
        XCTAssertFalse(app.staticTexts["discoveryStatus"].exists)
    }
    @MainActor func testInlineConnectionAndEmptyErrorStates() throws {
        let app=fresh();app.buttons["emptyEdit"].tap()
        app.buttons["connectSMB"].tap()
        XCTAssertTrue(app.textFields["prototypeServer"].exists)
        XCTAssertTrue(app.buttons["localDemoSource"].exists)
        app.buttons["prototypeConnect"].tap()
        XCTAssertTrue(app.staticTexts["connectionError"].exists)
        app.buttons["取消"].tap();app.buttons["smbDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-Videos"].waitForExistence(timeout:5));app.buttons["entry-Videos"].tap()
        XCTAssertTrue(app.buttons["entry-空資料夾"].waitForExistence(timeout:5));app.buttons["entry-空資料夾"].tap()
        XCTAssertTrue(app.staticTexts["空資料夾"].firstMatch.waitForExistence(timeout:5))
        app.buttons["folderBack"].tap()
        XCTAssertTrue(app.buttons["entry-讀取失敗範例"].waitForExistence(timeout:5));app.buttons["entry-讀取失敗範例"].tap()
        XCTAssertTrue(app.staticTexts["listingError"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["addShortcut"].isEnabled)
    }
    @MainActor func testFinderTagInitialsSortingAndVisibility() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview"];app.launch()
        let blue=app.descendants(matching:.any).matching(identifier:"tags-A-藍色.mp4").firstMatch
        XCTAssertTrue(blue.waitForExistence(timeout:10))
        let loaded=NSPredicate(format:"label == %@","Yellow")
        expectation(for:loaded,evaluatedWith:blue);waitForExpectations(timeout:10)
        XCTAssertEqual(Set(app.descendants(matching:.any).matching(identifier:"tags-B-紅綠藍.mp4").firstMatch.label.components(separatedBy:"、")),Set(["Orange","Yellow","旅行"]))
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-D-無色.mp4").firstMatch.label,"👩🏽‍💻工作")
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-E-無標籤.mp4").firstMatch.label,"無標籤")
        XCTAssertFalse(app.staticTexts["—"].exists)
        XCTAssertFalse(app.staticTexts["未提供"].exists)
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-F-未提供.mp4").firstMatch.label,"未提供")
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-G-不支援.mp4").firstMatch.label,"不支援")
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-H-無權限.mp4").firstMatch.label,"無權限")
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-I-格式錯誤.mp4").firstMatch.label,"格式錯誤")
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"tags-J-讀取失敗.mp4").firstMatch.label,"讀取失敗")
        app.buttons["columnOptions"].tap();app.buttons["refreshDirectory"].tap()
        expectation(for:loaded,evaluatedWith:blue);waitForExpectations(timeout:10)
        app.buttons["sort-tags"].tap()
        XCTAssertTrue(app.buttons["partialTagSort"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["tagSortStatus"].exists)
        XCTAssertGreaterThan(app.staticTexts["tagSortStatus"].frame.minX,app.staticTexts["prototypePath"].frame.minX)
        app.buttons["retryTagSort"].tap();XCTAssertTrue(app.buttons["partialTagSort"].waitForExistence(timeout:10));app.buttons["partialTagSort"].tap()
        XCTAssertTrue(app.buttons["entry-C-紅色.mp4"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["entry-C-紅色.mp4"].frame.minY,app.buttons["entry-A-藍色.mp4"].frame.minY)
        app.buttons["sort-tags"].tap()
        XCTAssertTrue(app.buttons["partialTagSort"].waitForExistence(timeout:10));app.buttons["partialTagSort"].tap()
        XCTAssertLessThan(app.buttons["entry-A-藍色.mp4"].frame.minY,app.buttons["entry-C-紅色.mp4"].frame.minY)
        app.scrollViews["directoryScroll"].swipeUp()
        XCTAssertTrue(app.staticTexts["無權限"].exists || app.descendants(matching:.any).matching(identifier:"tags-H-無權限.mp4").firstMatch.exists)
        app.buttons["columnOptions"].tap();app.buttons["toggleTags"].tap()
        XCTAssertFalse(app.buttons["sort-tags"].exists)
        app.buttons["columnOptions"].tap();app.buttons["toggleTags"].tap()
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"降冪")
    }
    @MainActor func testTagInitialsNarrowColumnAndFullNameMenu() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--narrow-tags"];app.launch()
        let tags=app.descendants(matching:.any).matching(identifier:"tags-B-紅綠藍.mp4").firstMatch
        XCTAssertTrue(tags.waitForExistence(timeout:10))
        let loaded=NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@","Orange","Yellow","旅行")
        expectation(for:loaded,evaluatedWith:tags);waitForExpectations(timeout:10)
        tags.press(forDuration:1.2)
        XCTAssertTrue(app.staticTexts["Orange"].waitForExistence(timeout:5) || app.buttons["Orange"].exists)
        XCTAssertTrue(app.staticTexts["Yellow"].exists || app.buttons["Yellow"].exists)
    }
    @MainActor func testFullFolderTagSortFiveThousandAndCancellation() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--full-tags-fixture"];app.launch()
        XCTAssertTrue(app.buttons["sort-tags"].waitForExistence(timeout:10));app.buttons["sort-tags"].tap()
        XCTAssertTrue(app.buttons["cancelTagSort"].waitForExistence(timeout:10));app.buttons["cancelTagSort"].tap()
        XCTAssertTrue(app.staticTexts["已暫停標籤讀取"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"升冪")
        app.buttons["resumeTags"].tap()
        waitForTags(app,count:5000)
        XCTAssertTrue(app.buttons["entry-影片 5000.mp4"].exists)
        app.buttons["sort-tags"].tap()
        XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].exists)
        app.buttons["sort-name"].tap()
        XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].waitForExistence(timeout:10))
        waitForTags(app,count:5000)
    }
    @MainActor func testMissingTagsCompleteWithoutRetry() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--full-tags-fixture","--missing-tags-fixture"];app.launch()
        waitForTags(app,count:5000)
        XCTAssertFalse(app.buttons["retryTagSort"].exists)
        XCTAssertTrue(app.buttons["sort-tags"].exists);app.buttons["sort-tags"].tap()
        waitForTags(app,count:5000)
        XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].exists)
        XCTAssertFalse(app.buttons["retryTagSort"].exists)
    }
    @MainActor func testAutomaticTagsOnNavigationPreserveDescendingSort() throws {
        let app=XCUIApplication();app.launchArguments=["--shortcut-ui-tests","--columns-preview","--tags-preview","--full-tags-fixture","--auto-tags-navigation"];app.launch()
        waitForTags(app,count:2)
        app.buttons["columnOptions"].tap();app.buttons["toggleModified"].tap()
        app.buttons["sort-modified"].tap()
        waitForTags(app,count:2)
        app.buttons["entry-電影"].tap()
        waitForTags(app,count:3)
        XCTAssertEqual(app.buttons["sort-modified"].value as? String,"升冪")
        app.buttons["folderBack"].tap()
        waitForTags(app,count:2)
        app.buttons["columnOptions"].tap();app.buttons["toggleModified"].tap()
        app.buttons["sort-tags"].tap()
        waitForTags(app,count:2)
        app.buttons["sort-tags"].tap()
        app.buttons["entry-電影"].tap()
        waitForTags(app,count:3)
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"降冪")
        app.buttons["folderBack"].tap()
        waitForTags(app,count:2)
        XCTAssertEqual(app.buttons["sort-tags"].value as? String,"降冪")
    }
    @MainActor func testLargeDirectoryTagCancellationAndNavigation() throws {
        let app=fresh();app.buttons["emptyEdit"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-大量影片"].waitForExistence(timeout:5));app.buttons["entry-大量影片"].tap()
        XCTAssertTrue(app.buttons["entry-影片 0001.mp4"].waitForExistence(timeout:10));app.buttons["addShortcut"].tap();app.buttons["editShortcuts"].tap()
        app.buttons["columnOptions"].tap();app.buttons["toggleTags"].tap()
        XCTAssertTrue(app.staticTexts["tagSortStatus"].waitForExistence(timeout:5))
        app.buttons["columnOptions"].tap();app.buttons["toggleTags"].tap()
        app.scrollViews["directoryScroll"].swipeUp()
        app.buttons["editShortcuts"].tap();app.buttons["localDemoSource"].tap()
        XCTAssertTrue(app.buttons["entry-空資料夾"].waitForExistence(timeout:5));app.buttons["entry-空資料夾"].tap()
        XCTAssertTrue(app.staticTexts["emptyDirectoryLabel"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["entry-影片 0001.mp4"].exists)
    }
    @MainActor func testSavedLoginRecoveryReplacementAndRemoval() throws {
        let app=XCUIApplication()
        let base=["--shortcut-ui-tests","--source-settings-fixture","--source-shortcut-fixture","--saved-login-fixture"]
        app.launchArguments=base+["--reset-shortcut-fixture"];app.launch()
        XCTAssertTrue(app.buttons["entry-合成登入成功"].waitForExistence(timeout:10))
        app.terminate();app.launchArguments=base+["--auth-expired"];app.launch()
        XCTAssertTrue(app.buttons["reconnectSMB"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["shortcut-保留的捷徑"].exists)
        app.buttons["reconnectSMB"].tap();app.buttons["prototypeConnect"].tap()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout:5))
        app.terminate();app.launchArguments=base;app.launch()
        XCTAssertTrue(app.buttons["entry-合成登入成功"].waitForExistence(timeout:10))
        app.terminate();app.launchArguments=base+["--auth-expired"];app.launch()
        XCTAssertTrue(app.buttons["reconnectSMB"].waitForExistence(timeout:10));app.buttons["reconnectSMB"].tap()
        let account=app.textFields["prototypeUsername"];account.tap();account.typeText("-updated")
        let secret=app.secureTextFields["prototypePassword"];secret.tap();secret.typeText("synthetic-new")
        app.buttons["prototypeConnect"].tap()
        XCTAssertTrue(app.buttons["entry-合成登入成功"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["shortcut-保留的捷徑"].exists)
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["entry-合成登入成功"].waitForExistence(timeout:10))
        app.buttons["editShortcuts"].tap();app.buttons["sourceSettings-測試分享"].tap()
        XCTAssertEqual(app.textFields["prototypeUsername"].value as? String,"original-user-updated")
        app.buttons["sourceRemove-測試分享"].tap();app.buttons["cancelSourceRemoval"].tap()
        XCTAssertTrue(app.buttons["prototypeConnect"].exists)
        app.buttons["sourceRemove-測試分享"].tap();app.buttons["confirmSourceRemoval"].tap()
        XCTAssertTrue(app.staticTexts["prototypeNotice"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["prototypeNotice"].label,"合成憑證已清除")
        XCTAssertFalse(app.buttons["sourceSettings-測試分享"].exists)
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["editShortcuts"].waitForExistence(timeout:10));app.buttons["editShortcuts"].tap()
        XCTAssertFalse(app.buttons["sourceSettings-測試分享"].exists)
        XCTAssertFalse(app.descendants(matching:.any).matching(identifier:"rename-保留的捷徑").firstMatch.exists)
    }
    @MainActor func testKeychainSurvivesAppRelaunchAndCleansSyntheticEntry() throws {
        let app=XCUIApplication();app.launchArguments=["--credential-self-test-write"];app.launch()
        let result=app.staticTexts["credentialTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout:10));XCTAssertEqual(result.label,"測試憑證已保存")
        app.terminate();app.launchArguments=["--credential-self-test-read"];app.launch()
        XCTAssertTrue(result.waitForExistence(timeout:10));XCTAssertEqual(result.label,"測試憑證恢復與清理成功")
    }
}
