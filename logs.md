# DiskLens logs

## 2026-10-28 — 에이전트 연동: JSON 내보내기, MCP 서버, Claude 판정 표시 (0.3.0)

- 변경 파일: `Sources/DiskLens/App/Entry.swift`, `Headless/`, `Core/UsageTree.swift`, `Core/Annotations.swift`, `Model/AnnotationCenter.swift`, `Views/ClaudeBanner.swift`와 기존 화면 3개
- 요약: Claude Code의 `storage-cleanup` skill이 DiskLens 엔진을 쓰도록 `--export`(JSON)와 `--mcp`(stdio MCP 서버)를 추가했습니다. Claude가 남긴 판정(`annotations.json`)은 앱의 배너, 목록 배지, 차트 테두리로 보여줍니다.

내보내기와 MCP는 같은 `UsageNode` 트리를 씁니다. 최소 크기보다 작은 항목은 각 폴더의 `otherSize`로 접어 넣기 때문에, 홈 폴더(142만 파일)도 50MB 기준이면 JSON 353KB입니다. MCP 서버는 스캔 결과를 메모리에 두고 `list`와 `largest_files`에 바로 답합니다. `du`를 여러 번 도는 대신 한 번 스캔한 뒤 조회하게 만든 것이 핵심입니다. 화면이 없을 때는 `Scanner.liveSnapshots = false`로 차트용 스냅숏(초당 20회 트리 복사)을 건너뜁니다.

판정을 앱에 넘기는 통로로는 파일(`~/Library/Application Support/DiskLens/annotations.json`)을 골랐습니다. MCP 서버는 Claude Code가 띄우는 별도 프로세스라 앱과 메모리를 공유하지 않고, 파일로 넘기면 MCP 없이 skill이 직접 써도 됩니다. 앱은 2초마다 수정 시각만 확인합니다.

⚠️ **`NSTreatUnknownArgumentsAsOpen`을 지우면 안 됩니다.** AppKit은 경로처럼 생긴 실행 인자를 "열 문서"로 처리하는데, SwiftUI 앱은 실행하면서 문서를 열면 첫 창을 만들지 않습니다. 그래서 README의 `open -a DiskLens --args /folder`는 0.2.0에서도 창 없이 대기만 했습니다. `Entry`에서 이 기본값을 `NO`로 등록해 고쳤습니다.

⚠️ **전체 디스크 접근 권한은 "책임 프로세스"를 따라갑니다.** 터미널에서 바이너리를 직접 실행하면 터미널의 권한으로 스캔합니다. DiskLens 자신의 권한을 쓰려면 `open -n -W -a DiskLens --args --export /abs/path.json <folder>`로 LaunchServices를 거쳐야 하고, 출력 경로는 절대 경로여야 합니다. `--mcp`는 Claude Code가 직접 띄우므로 이 방법을 쓸 수 없습니다. 화면 없이 실행할 때는 `setActivationPolicy(.prohibited)`로 Dock 아이콘이 생기지 않게 했습니다.

`move_to_trash`는 홈 폴더 아래와 `/Applications`만 허용하고, 홈 바로 아래 폴더(`~/Library` 등)는 통째로 옮기지 못하게 막았습니다. 휴지통으로 옮겨도 비우기 전에는 공간이 돌아오지 않는다는 점을 응답에 항상 넣습니다.

시험 중 함정: Claude Code의 백그라운드 세션에서 `open -n`으로 띄운 앱은 창이 뜨지 않았습니다(0.2.0도 같음). 화면이 필요한 확인은 바이너리를 직접 실행해서 해야 합니다. 그 세션에는 화면 기록 권한도 없어서 `screencapture -l`이 실패합니다.
