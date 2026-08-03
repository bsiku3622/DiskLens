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
    }
}
