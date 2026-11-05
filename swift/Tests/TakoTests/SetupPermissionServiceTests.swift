/*
 * tako — Setup permission service unit tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AVFoundation
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct SetupPermissionServiceTests {

    @Test
    func snapshotDoesNotTriggerRequestsAndReturnsAllSupportedPermissions() async throws {
        var requestCount = 0
        let service = TerminalPermissionService(
            authorization: { _ in .authorized },
            screenCaptureCheck: { true },
            screenCaptureRequest: { requestCount += 1; return true },
            request: { _ in
                requestCount += 1
                return true
            }
        )

        let rows = await service.snapshot()
        #expect(requestCount == 0, "snapshot() must never trigger explicit permission requests")
        #expect(rows.count == 7)
        #expect(!rows.contains { $0.id == "camera" })
        #expect(rows.map(\.kind) == TerminalPermissionKind.allCases)
        #expect(service.rows == rows)
        #expect(service.permissions == rows)
    }

    @Test
    func microphoneStatusesMapping() async throws {
        let statuses: [(AVAuthorizationStatus, TerminalPermissionStatus)] = [
            (.authorized, .allowed),
            (.denied, .denied),
            (.notDetermined, .notAsked),
            (.restricted, .restricted),
            (AVAuthorizationStatus(rawValue: 888) ?? .notDetermined, .unknown),
        ]

        for (avStatus, expected) in statuses {
            let service = TerminalPermissionService(
                authorization: { mediaType in
                    #expect(mediaType == .audio)
                    return avStatus
                }
            )
            let status = await service.status(for: .microphone)
            #expect(status == expected)
            let checkStatus = await service.check(kind: .microphone)
            #expect(checkStatus == expected)
        }
    }

    @Test
    func screenCapturePreflightAllowedVsNotAllowed() async throws {
        let allowedService = TerminalPermissionService(screenCaptureCheck: { true })
        let allowedStatus = await allowedService.status(for: .screenCapture)
        #expect(allowedStatus == .allowed)

        let notAllowedService = TerminalPermissionService(screenCaptureCheck: { false })
        let notAllowedStatus = await notAllowedService.status(for: .screenCapture)
        #expect(notAllowedStatus == .notAllowed)
        #expect(notAllowedStatus != .denied, "CGPreflight cannot falsely distinguish denied")
        #expect(notAllowedStatus != .notAsked, "CGPreflight cannot falsely distinguish notAsked")
    }

    @Test
    func unpreflightablePermissionsReportManagedInSettingsHonestly() async throws {
        let service = TerminalPermissionService()
        let unprovableKinds: [TerminalPermissionKind] = [
            .protectedFolders,
            .fullDiskAccess,
            .localNetwork,
            .systemAudio,
            .automation,
        ]

        for kind in unprovableKinds {
            let status = await service.status(for: kind)
            #expect(status == .managedInSettings, "\(kind) must report managedInSettings honestly")
        }
    }

    @Test
    func customCheckClosureOverridesStatus() async throws {
        let service = TerminalPermissionService(
            check: { kind in
                switch kind {
                case .fullDiskAccess: return .unknown
                case .automation: return .restricted
                case .localNetwork: return .allowed
                default: return nil
                }
            }
        )

        #expect(await service.status(for: .fullDiskAccess) == .unknown)
        #expect(await service.status(for: .automation) == .restricted)
        #expect(await service.status(for: .localNetwork) == .allowed)
        #expect(await service.status(for: .protectedFolders) == .managedInSettings)
    }

    @Test
    func requestMicrophoneSuccessUpdatesStatusAndReturnsCompactResult() async throws {
        var avStatus: AVAuthorizationStatus = .notDetermined
        var requestMediaType: AVMediaType?

        let service = TerminalPermissionService(
            authorization: { _ in avStatus },
            request: { mediaType in
                requestMediaType = mediaType
                avStatus = .authorized
                return true
            }
        )

        await service.snapshot()
        let result = await service.request(.microphone)

        #expect(requestMediaType == .audio)
        #expect(result.kind == .microphone)
        #expect(result.status == .allowed)
        #expect(result.isAllowed)
        #expect(result.didPrompt)
        #expect(!result.isRefused)
        #expect(result.message.contains("Microphone access granted"))
        #expect(service.permission(for: .microphone)?.status == .allowed)
    }

    @Test
    func requestMicrophoneAlreadyAllowedReturnsWithoutReRequesting() async throws {
        var requestInvoked = false
        let service = TerminalPermissionService(
            authorization: { _ in .authorized },
            request: { _ in
                requestInvoked = true
                return true
            }
        )

        let result = await service.request(.microphone)
        #expect(!requestInvoked, "Already allowed permission should not invoke request access closure")
        #expect(result.kind == .microphone)
        #expect(result.status == .allowed)
        #expect(result.isAllowed)
        #expect(!result.didPrompt)
        #expect(result.message.contains("already allowed"))
    }

    @Test
    func deniedOrRestrictedRequestsDoNotPretendToPromptAgain() async {
        for avStatus in [AVAuthorizationStatus.denied, .restricted] {
            var calls = 0
            let service = TerminalPermissionService(authorization: { _ in avStatus },
                request: { _ in calls += 1; return false })
            let result = await service.request(.microphone)
            #expect(calls == 0)
            #expect(!result.didPrompt)
            #expect(result.message.contains("System Settings"))
        }
    }

    @Test
    func requestMicrophoneDeniedReturnsHelpfulMessage() async throws {
        var avStatus: AVAuthorizationStatus = .notDetermined

        let service = TerminalPermissionService(
            authorization: { _ in avStatus },
            request: { _ in
                avStatus = .denied
                return false
            }
        )

        let result = await service.request(kind: .microphone)
        #expect(result.kind == .microphone)
        #expect(result.status == .denied)
        #expect(!result.isAllowed)
        #expect(result.didPrompt)
        #expect(result.message.contains("denied"))
        #expect(result.message.contains("System Settings"))
    }

    @Test
    func requestRefusesUnsupportedPermissionsWithoutPrompting() async throws {
        var requestCount = 0
        let service = TerminalPermissionService(
            request: { _ in
                requestCount += 1
                return true
            }
        )

        let unsupportedKinds: [TerminalPermissionKind] = [
            .protectedFolders,
            .fullDiskAccess,
            .localNetwork,
            .systemAudio,
            .automation,
        ]

        for kind in unsupportedKinds {
            let result = await service.request(kind)
            #expect(requestCount == 0, "Unsupported permission \(kind) must not invoke request closure")
            #expect(result.kind == kind)
            #expect(!result.didPrompt)
            #expect(result.isRefused)
            #expect(result.message.contains("cannot be requested directly"))
            #expect(result.message.contains("System Settings"))
        }
    }

    @Test
    func openSettingsDispatchesAppropriateURL() throws {
        var openedURLs: [URL] = []
        let service = TerminalPermissionService(
            open: { url in
                openedURLs.append(url)
                return true
            }
        )

        for kind in TerminalPermissionKind.allCases {
            let success = service.openSettings(kind)
            #expect(success)
        }

        #expect(openedURLs.count == TerminalPermissionKind.allCases.count)
        let urlStrings = openedURLs.map(\.absoluteString)
        #expect(urlStrings.contains { $0.contains("Privacy_Microphone") })
        #expect(urlStrings.contains { $0.contains("Privacy_ScreenCapture") })
        #expect(urlStrings.contains { $0.contains("Privacy_AllFiles") })
        #expect(urlStrings.contains { $0.contains("Privacy_FilesAndFolders") })
        #expect(urlStrings.contains { $0.contains("Privacy_LocalNetwork") })
        #expect(urlStrings.contains { $0.contains("Privacy_AudioCapture") })
        #expect(urlStrings.contains { $0.contains("Privacy_Automation") })
    }

    @Test func screenRequestUsesSystemConsentWithoutCapturing() async {
        var calls = 0
        let service = TerminalPermissionService(screenCaptureCheck: { false },
            screenCaptureRequest: { calls += 1; return true })
        await service.snapshot()
        #expect(calls == 0)
        let result = await service.request(.screenCapture)
        #expect(calls == 1)
        #expect(result.status == .allowed)
        #expect(result.didPrompt)
        #expect(service.permission(for: .screenCapture)?.status == .allowed)
    }

    @Test func screenRequestDoesNotClaimDenialOrPermissionWhenNotGranted() async {
        let service = TerminalPermissionService(screenCaptureCheck: { false }, screenCaptureRequest: { false })
        let result = await service.request(.screenCapture)
        #expect(result.status == .notAllowed)
        #expect(!result.isAllowed)
    }

    @Test func authorizedScreenDoesNotRequestAgain() async {
        let service = TerminalPermissionService(screenCaptureCheck: { true }, screenCaptureRequest: {
            Issue.record("Already authorized screen access must not prompt")
            return true
        })
        #expect(!(await service.request(.screenCapture)).didPrompt)
    }

    @Test
    func stableIDsAndClearChildProcessExplanations() throws {
        for kind in TerminalPermissionKind.allCases {
            #expect(kind.id == kind.rawValue)
            #expect(!kind.title.isEmpty)
            #expect(!kind.explanation.isEmpty)

            let model = TerminalPermission(kind: kind, status: .managedInSettings)
            #expect(model.id == kind.rawValue)
            #expect(model.title == kind.title)
            #expect(model.explanation == kind.explanation)
        }
    }
}
