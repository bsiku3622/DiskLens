import Foundation

/// App language, chosen in the toolbar (not tied to the system locale).
enum Lang: String, CaseIterable, Identifiable {
    case en, ko
    var id: String { rawValue }
    var label: String { self == .ko ? "한국어" : "English" }

    /// First-run default: follow the system language, else English.
    static var initial: Lang {
        if let saved = UserDefaults.standard.string(forKey: "appLanguage"),
           let lang = Lang(rawValue: saved) { return lang }
        return (Locale.preferredLanguages.first?.hasPrefix("ko") == true) ? .ko : .en
    }

    static var current: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? initial
    }
}

enum LKey {
    case appName
    case chooseFolder, rescan, cancel, scanning, scanningDetail
    case emptyTitle, emptyHint
    case totalSize, items, files, folders
    case detailTitle, noSelection, noSelectionHint
    case contents, upToParent, largest
    case revealInFinder, moveToTrash, moveToTrashConfirm, moveToTrashMessage
    case trashed, trashFailed, deleteKeep, deleteConfirm
    case percentOfParent, empty
    case scanFailed, permissionHint
    case scanningItem
    case deniedBanner, deniedBannerProtected, deniedBannerMixed
    case grantFullDiskAccess, deniedDismiss
    case deniedShowFolders, deniedHideFolders, deniedListMore
    case systemReserved, diskActual, cloneNote
    case updateAvailable, updateNow, updateLater, updateDownloading, updateInstalling, updateFailed, checkForUpdates
    case quickPickWholeDisk, quickPickHome, quickPickDownloads, quickPickDocuments, quickPickDesktop
    case verdictSafe, verdictReview, verdictKeep
    case marksBanner, marksReclaimable, marksShowList, marksClear, marksInside
    case agentButtonHelp, agentAsk, agentPickTitle, agentPickHint, agentConfirm
    case agentNotInstalled, agentNotInstalledHelp
    case agentNewChat, agentStop, agentSend, agentPlaceholder, agentClose, agentEmptyHint
    case agentFailed, agentStopped
    case agentStatusStarting, agentStatusThinking, agentStatusWriting, agentThoughtFor, agentReasoning
    case agentModel, agentEffort, agentModelHelp, agentTokens, agentCopy, agentCopied
    case agentPromptAnalyze, agentPromptAnalyzeNoScan, agentPromptItem
    case actCurrentScan, actScan, actList, actLargest, actAnnotate, actTrash
    case actRead, actRun, actFind, actSearch
}

/// Localized string. Views pass an @AppStorage-tracked `lang` so they re-render on change.
func L(_ key: LKey, _ lang: Lang = .current) -> String {
    let ko = lang == .ko
    switch key {
    case .appName:            return "DiskLens"
    case .chooseFolder:       return ko ? "폴더 선택" : "Choose Folder"
    case .rescan:             return ko ? "다시 스캔" : "Rescan"
    case .cancel:             return ko ? "취소" : "Cancel"
    case .scanning:           return ko ? "스캔 중…" : "Scanning…"
    case .scanningDetail:     return ko ? "%d개 항목 · %@" : "%d items · %@"
    case .emptyTitle:         return ko ? "분석할 폴더를 선택하세요" : "Choose a folder to analyze"
    case .emptyHint:          return ko ? "폴더를 고르면 하위 항목의 용량을 방사형 차트로 보여줍니다."
                                        : "Pick a folder and DiskLens maps what's using space as a sunburst."
    case .totalSize:          return ko ? "총 용량" : "Total"
    case .items:              return ko ? "항목" : "items"
    case .files:              return ko ? "파일" : "files"
    case .folders:            return ko ? "폴더" : "folders"
    case .detailTitle:        return ko ? "내용" : "Contents"
    case .noSelection:        return ko ? "선택된 항목 없음" : "Nothing selected"
    case .noSelectionHint:    return ko ? "차트에서 조각을 클릭하면 안으로 들어갑니다." : "Click a slice to drill in."
    case .contents:           return ko ? "내용" : "Contents"
    case .upToParent:         return ko ? "상위 폴더" : "Up"
    case .largest:            return ko ? "가장 큰 항목" : "Largest items"
    case .revealInFinder:     return ko ? "Finder에서 보기" : "Reveal in Finder"
    case .moveToTrash:        return ko ? "휴지통으로 이동" : "Move to Trash"
    case .moveToTrashConfirm: return ko ? "휴지통으로 이동" : "Move to Trash"
    case .moveToTrashMessage: return ko ? "\"%@\"을(를) 휴지통으로 옮길까요? 나중에 복원할 수 있습니다."
                                        : "Move \"%@\" to the Trash? You can restore it later."
    case .trashed:            return ko ? "휴지통으로 이동함" : "Moved to Trash"
    case .trashFailed:        return ko ? "휴지통으로 옮기지 못했습니다" : "Couldn't move to Trash"
    case .deleteKeep:         return ko ? "그대로 두기" : "Keep"
    case .deleteConfirm:      return ko ? "이동" : "Move"
    case .percentOfParent:    return ko ? "상위의 %@" : "%@ of parent"
    case .empty:              return ko ? "비어 있음" : "Empty"
    case .scanFailed:         return ko ? "스캔에 실패했습니다" : "Scan failed"
    case .permissionHint:     return ko ? "일부 폴더는 시스템 권한이 필요할 수 있습니다."
                                        : "Some folders may require system permission."
    case .scanningItem:       return ko ? "%@ 스캔 중…" : "Scanning %@…"
    case .deniedBanner:       return ko ? "권한 때문에 %d개 폴더를 읽지 못했습니다. 전체 디스크 접근을 허용하면 스캔됩니다."
                                        : "Couldn't read %d folders without permission. Grant Full Disk Access and they'll be scanned."
    case .deniedBannerProtected:
                              return ko ? "%d개 폴더는 시스템이 보호하고 있어 읽을 수 없습니다. 관리자 소유라 전체 디스크 접근으로는 열리지 않습니다."
                                        : "%d folders are system-protected and can't be read. They're owned by root, so Full Disk Access won't open them."
    case .deniedBannerMixed:  return ko ? "%d개 폴더를 읽지 못했습니다 — 전체 디스크 접근으로 열리는 곳 %d개, 시스템이 보호하는 곳 %d개."
                                        : "Couldn't read %d folders — %d that Full Disk Access would unlock, %d that are system-protected."
    case .grantFullDiskAccess: return ko ? "전체 디스크 접근 허용" : "Grant Full Disk Access"
    case .deniedDismiss:      return ko ? "닫기" : "Dismiss"
    case .deniedShowFolders:  return ko ? "어떤 폴더인지 보기" : "Which folders?"
    case .deniedHideFolders:  return ko ? "목록 접기" : "Hide list"
    case .deniedListMore:     return ko ? "외 %d개 더" : "and %d more"
    case .systemReserved:     return ko ? "시스템 예약" : "System Reserved"
    case .diskActual:         return ko ? "디스크 실사용 %@" : "%@ actually on disk"
    case .cloneNote:          return ko ? "스캔 합계는 파일마다 할당된 크기를 더한 값입니다. APFS 복제본이 블록을 공유하면 같은 블록이 여러 번 세어져 실제 사용량보다 커집니다."
                                        : "The scanned total sums each file's allocated size. Where APFS clones share blocks, those blocks are counted once per clone, so the total runs above what the disk actually holds."
    case .updateAvailable:    return ko ? "새 버전 %@ 이(가) 있습니다." : "Version %@ is available."
    case .updateNow:          return ko ? "업데이트" : "Update"
    case .updateLater:        return ko ? "나중에" : "Later"
    case .updateDownloading:  return ko ? "다운로드 중… %d%%" : "Downloading… %d%%"
    case .updateInstalling:   return ko ? "설치 후 재시작 중…" : "Installing…"
    case .updateFailed:       return ko ? "업데이트 실패" : "Update failed"
    case .checkForUpdates:    return ko ? "업데이트 확인" : "Check for Updates"
    case .quickPickWholeDisk: return ko ? "전체 디스크" : "Whole Disk"
    case .quickPickHome:      return ko ? "홈" : "Home"
    case .quickPickDownloads: return ko ? "다운로드" : "Downloads"
    case .quickPickDocuments: return ko ? "문서" : "Documents"
    case .quickPickDesktop:   return ko ? "데스크탑" : "Desktop"
    case .verdictSafe:        return ko ? "정리 가능" : "Safe to remove"
    case .verdictReview:      return ko ? "확인 필요" : "Review"
    case .verdictKeep:        return ko ? "유지" : "Keep"
    case .marksBanner:        return ko ? "%@가 %d개 항목을 표시했습니다." : "%@ marked %d items."
    case .marksReclaimable:   return ko ? "정리 가능 %@" : "%@ reclaimable"
    case .marksShowList:      return ko ? "목록 보기" : "Show list"
    case .marksClear:         return ko ? "표시 지우기" : "Clear marks"
    case .marksInside:        return ko ? "안쪽에 AI가 표시한 항목 %d개" : "%d items marked by AI inside"
    case .agentButtonHelp:    return ko ? "AI와 이야기하기" : "Talk to AI"
    case .agentAsk:           return ko ? "AI에게 묻기" : "Ask AI"
    case .agentPickTitle:     return ko ? "어떤 AI와 이야기할까요?" : "Which AI would you like to use?"
    case .agentPickHint:      return ko ? "이 Mac에 설치된 에이전트가 지금 보고 있는 스캔을 직접 살펴봅니다. 확인을 누르면 질문이 채워진 채팅창이 열리고, 보내기를 누르기 전에는 아무것도 실행하지 않습니다."
                                        : "An agent installed on this Mac looks at the scan you're viewing. Confirm opens the chat with a question filled in; nothing runs until you send it."
    case .agentConfirm:       return ko ? "확인" : "Confirm"
    case .agentNotInstalled:  return ko ? "설치되지 않음" : "Not installed"
    case .agentNotInstalledHelp: return ko ? "%@를 설치하고 터미널에서 로그인하면 쓸 수 있습니다." : "Install %@ and sign in from the Terminal to use it."
    case .agentNewChat:       return ko ? "새 대화" : "New chat"
    case .agentStop:          return ko ? "중지" : "Stop"
    case .agentSend:          return ko ? "보내기" : "Send"
    case .agentPlaceholder:   return ko ? "디스크에 대해 물어보세요…" : "Ask about your disk…"
    case .agentClose:         return ko ? "닫기" : "Close"
    case .agentEmptyHint:     return ko ? "입력창의 질문을 확인하고 보내기를 누르세요. 답은 지금 보고 있는 스캔을 기준으로 하고, 판정은 차트에 표시됩니다."
                                        : "Check the question below and press Send. Answers are based on the scan you're viewing, and verdicts appear on the chart."
    case .agentFailed:        return ko ? "응답 중 문제가 생겼습니다." : "The agent ran into a problem."
    case .agentStopped:       return ko ? "응답을 멈췄습니다. 다음 메시지에서 대화를 이어갑니다." : "Stopped. Your next message continues the conversation."
    case .agentStatusStarting: return ko ? "준비 중…" : "Starting…"
    case .agentStatusThinking: return ko ? "생각 중" : "Thinking"
    case .agentStatusWriting: return ko ? "답변 작성 중…" : "Writing…"
    case .agentThoughtFor:    return ko ? "%@ 동안 생각함" : "Thought for %@"
    case .agentReasoning:     return ko ? "생각 요약" : "Reasoning"
    case .agentModel:         return ko ? "모델" : "Model"
    case .agentEffort:        return ko ? "추론 강도" : "Reasoning"
    case .agentModelHelp:     return ko ? "모델과 추론 강도 — 다음 메시지부터 적용됩니다" : "Model and reasoning level — applies from your next message"
    case .agentTokens:        return ko ? "입력 %@ · 출력 %@ 토큰" : "%@ in · %@ out tokens"
    case .agentCopy:          return ko ? "복사" : "Copy"
    case .agentCopied:        return ko ? "복사됨" : "Copied"
    case .agentPromptAnalyze: return ko ? "지금 스캔한 %@를 storage-cleanup 지침의 1단계대로 상세 분석해줘. 용량을 차지하는 주범을 찾아 판정을 표시하고 목록으로 요약해줘. 지우는 건 내가 고른 뒤에만 해."
                                        : "Analyze %@, which I just scanned, following step 1 of the storage-cleanup playbook. Find what's taking the space, mark verdicts, and sum them up as a list. Delete nothing until I choose."
    case .agentPromptAnalyzeNoScan: return ko ? "이 Mac의 디스크를 storage-cleanup 지침의 1단계대로 상세 분석해줘. 용량을 차지하는 주범을 찾아 판정을 표시하고 목록으로 요약해줘. 지우는 건 내가 고른 뒤에만 해."
                                              : "Analyze this Mac's disk following step 1 of the storage-cleanup playbook. Find what's taking the space, mark verdicts, and sum them up as a list. Delete nothing until I choose."
    case .agentPromptItem:    return ko ? "%@ (%@)가 무엇인지, 왜 이만큼 차지하는지, 정리해도 되는지 설명해줘. 판단이 서면 판정도 표시해줘."
                                        : "Explain what %@ (%@) is, why it takes this much space, and whether it's safe to clean up. Mark a verdict once you've judged it."
    case .actCurrentScan:     return ko ? "앱의 스캔 확인" : "Reading the app's scan"
    case .actScan:            return ko ? "스캔: %@" : "Scanning %@"
    case .actList:            return ko ? "살펴보는 중: %@" : "Looking at %@"
    case .actLargest:         return ko ? "큰 파일 찾는 중: %@" : "Finding large files in %@"
    case .actAnnotate:        return ko ? "판정 %d개 표시" : "Marked %d items"
    case .actTrash:           return ko ? "휴지통으로 이동: %d개" : "Moving %d items to the Trash"
    case .actRead:            return ko ? "읽는 중: %@" : "Reading %@"
    case .actRun:             return ko ? "확인: %@" : "Checking: %@"
    case .actFind:            return ko ? "찾는 중: %@" : "Searching %@"
    case .actSearch:          return ko ? "웹에서 찾는 중: %@" : "Searching the web: %@"
    }
}

/// Reasoning levels as the CLIs name them ("xhigh") → words for the picker.
func effortName(_ effort: String, _ lang: Lang = .current) -> String {
    let ko = lang == .ko
    switch effort {
    case "minimal": return ko ? "최소" : "Minimal"
    case "low": return ko ? "낮음" : "Low"
    case "medium": return ko ? "보통" : "Medium"
    case "high": return ko ? "높음" : "High"
    case "xhigh": return ko ? "매우 높음" : "Extra high"
    case "max": return ko ? "최대" : "Max"
    case "ultra": return ko ? "울트라" : "Ultra"
    default: return effort
    }
}
