import Foundation
import XCTest
@testable import SocialClimber

final class GoogleDriveServiceTests: XCTestCase {
    func testExpandedMetaFolderJSONPathsAreRecognized() {
        XCTAssertTrue(InstagramExportParser.isRelevantEntry(
            "your_instagram_activity/messages/inbox/jerry/message_1.json"
        ))
        XCTAssertTrue(InstagramExportParser.isRelevantEntry(
            "connections/followers_and_following/followers_1.json"
        ))
        XCTAssertTrue(InstagramExportParser.isRelevantEntry(
            "connections/followers_and_following/following.json"
        ))
    }

    func testExpandedMetaFolderIgnoresMediaAndHTML() {
        XCTAssertFalse(InstagramExportParser.isRelevantEntry(
            "your_instagram_activity/messages/inbox/jerry/photos/photo.jpg"
        ))
        XCTAssertFalse(InstagramExportParser.isRelevantEntry(
            "your_instagram_activity/messages/inbox/jerry/message_1.html"
        ))
    }

    func testHTMLExportErrorExplainsHowToFixTheFormat() {
        XCTAssertEqual(
            GoogleDriveError.htmlExportUnsupported.errorDescription,
            "This Meta export uses HTML format, but Instagram sync requires JSON. In Meta Accounts Center, create a new download in JSON format and select its Drive folder."
        )
    }

    func testDisabledDriveAPIReturnsConfigurationError() {
        let payload = #"{"error":{"code":403,"message":"Google Drive API has not been used in project 123 before or it is disabled.","errors":[{"reason":"accessNotConfigured"}]}}"#

        let error = GoogleDriveService.apiError(
            operation: "list files",
            statusCode: 403,
            data: Data(payload.utf8)
        )

        XCTAssertEqual(
            error.errorDescription,
            "Google Drive is authorized, but the Google Drive API is disabled for this OAuth project. Enable the Google Drive API in Google Cloud Console, wait a minute, then sync again."
        )
    }

    func testExpiredAuthorizationReturnsReconnectInstruction() {
        let payload = #"{"error":{"code":401,"message":"Invalid Credentials","errors":[{"reason":"authError"}]}}"#

        let error = GoogleDriveService.apiError(
            operation: "list files",
            statusCode: 401,
            data: Data(payload.utf8)
        )

        XCTAssertEqual(
            error.errorDescription,
            "Google Drive authorization expired or was revoked. Disconnect Google Drive, reconnect it, then sync again."
        )
    }

    func testUnknownGoogleErrorKeepsStatusReasonAndMessage() {
        let payload = #"{"error":{"code":403,"message":"The caller does not have permission","errors":[{"reason":"forbidden"}]}}"#

        let error = GoogleDriveService.apiError(
            operation: "download export",
            statusCode: 403,
            data: Data(payload.utf8)
        )

        XCTAssertEqual(
            error.errorDescription,
            "Google Drive rejected download export (HTTP 403) [forbidden]: The caller does not have permission"
        )
    }
}
