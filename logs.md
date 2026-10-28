# DiskLens logs

## 2026-10-28 — "DiskLens 응용 프로그램을 더 이상 열 수 없습니다" 수정

- 변경 파일: `Sources/DiskLens/App/Entry.swift`
- 요약: 0.3.0부터 `--mcp` 프로세스가 LaunchServices에 "실행 중인 DiskLens"로 등록돼서, 앱을 열면 macOS가 그 프로세스를 앞으로 불러오려다 실패했습니다. `--mcp`에서는 AppKit을 쓰지 않게 했습니다.

⚠️ **`--mcp` 경로에서 `NSApplication.shared`를 부르면 안 됩니다.** 화면 없는 실행에서 Dock 아이콘을 숨기려고 `NSApplication.shared.setActivationPolicy(.prohibited)`를 불렀는데, 이 호출 자체가 프로세스를 앱 인스턴스로 등록합니다(`lsappinfo list`에 `bundleID="com.jaewonbaek.disklens"`로 나오고, 하나는 `type="Foreground"`였음). MCP 서버는 Claude Code 세션이 오래 붙잡고 있고, 백그라운드 작업용 예비 세션(`claude bg-spare`)도 사용자 범위 MCP를 미리 띄웁니다. 그래서 Claude Code를 쓰지 않을 때도 앱이 안 열렸습니다. 같은 이유로 자동 업데이트의 마지막 단계(`open` 재실행)도 실패했을 겁니다. 이제는 LaunchServices로 띄우는 `--export`에서만 Dock 숨김을 씁니다. 확인 방법: `--mcp`로 띄운 뒤 `lsappinfo list | grep -c "pid = <pid> "`가 0이어야 합니다.

## 2026-10-28 — AI 사이드바: Claude Code·Codex 대화, 모델 선택, 생각·작업 표시 (0.4.0)

- 변경 파일: `Agents/`(새로 추가), `Model/AgentChat.swift`, `Views/AgentSidebar.swift`, `Core/CurrentScan.swift`, `Views/MarksBanner.swift`(`ClaudeBanner`에서 이름 변경), 기존 화면과 `MCPServer`
- 요약: 툴바 오른쪽 끝의 ✨ 버튼 하나로 에이전트·모델·추론 강도를 고르면, 상세 분석 프롬프트가 입력창에 채워진 채로 채팅이 열립니다. 보내기 전에는 아무것도 실행하지 않습니다. 사이드바는 생각, 도구 단계(진행·성공·실패, 시간, 결과), 턴별 시간·토큰을 보여줍니다.

에이전트마다 SDK를 붙이지 않고, 이미 설치된 CLI를 프로세스로 띄웁니다. 사용자의 로그인과 구독을 그대로 쓰기 위해서입니다. 두 CLI는 동작 방식이 다릅니다. Claude Code는 프로세스 하나에 stdin으로 stream-json 턴을 보내고, Codex는 턴마다 `codex exec`나 `exec resume <thread>`를 띄웁니다. 그래서 `AgentDriver`는 `send`·`stop`·`shutdown`만 정의하고, 이벤트(글자, 생각, 도구 시작·종료, 휴지통, 사용량, 종료)를 같은 형식으로 올립니다. 대화 화면, 권한 정책, 지침은 공통입니다.

⚠️ **사이드바는 사용자 설정을 읽으면 안 됩니다.** 이 Mac의 `~/.claude/settings.json`은 `defaultMode: bypassPermissions`라서, 허용 목록을 줘도 `touch`가 질문 없이 실행됐습니다(시험에서 실제로 파일이 생김). 그래서 Claude는 `--setting-sources project --permission-mode default --add-dir /`로 실행하고, Codex는 `--ignore-user-config`와 `sandbox_mode="read-only"`를 씁니다. 두 경우 모두 읽기 전용 명령만 통과하고 쓰기는 거부되는 것을 확인했습니다. 대가로 사용자 skill도 안 보이므로, storage-cleanup의 `SKILL.md`와 `hotspots.md`를 시스템 프롬프트(Claude) 또는 `developer_instructions`(Codex)에 넣습니다. 지침의 `rm -rf`와 스크립트보다 "휴지통 이동만" 규칙이 우선한다고 명시해뒀습니다.

사용자 설정을 끄면 모델 설정도 사라집니다. 그래서 사용자 설정의 모델과 추론 강도를 읽어 기본 선택값으로 쓰고, CLI에는 명시적으로 넘깁니다. Codex에는 함정이 있었습니다. 설정의 `gpt-6.1-sol`은 계정 모델 목록(`~/.codex/models_cache.json`)에 없어서 "not supported when using Codex with a ChatGPT account"로 거부됐습니다. 그래서 목록에 있는 모델만 보여주고, 사용자 설정의 모델은 목록에 있을 때만 기본값으로 씁니다. Codex는 MCP 호출도 승인 대상이라 `mcp_servers.disklens.default_tools_approval_mode="approve"`가 필요합니다(값은 `auto`·`prompt`·`writes`·`approve`). 추론 요약은 `model_reasoning_summary="auto"`를 켜야 옵니다. `exec resume`은 `-s`와 `-m`을 받지 않으므로 모든 설정을 `-c`로 넘깁니다.

스트림을 읽을 때 함정 두 가지. 파이프의 `readabilityHandler`는 EOF에서 빈 데이터로 계속 불리므로 해제해야 합니다(Codex는 턴마다 프로세스가 끝남). 조각마다 `Task { @MainActor }`를 쓰면 순서가 보장되지 않아서 `DispatchQueue.main.async`로 넘깁니다. 중지한 턴의 늦은 이벤트는 `AgentChat`이 턴이 진행 중일 때만 받는 방식으로 버립니다. Claude가 생각 내용을 보내지 않으면 빈 thinking이 오므로, 내용이 없고 1.5초 미만인 생각 조각은 지웁니다. Codex는 추론 요약을 끝났을 때만 주는 경우가 많아서, 1초 미만이면 시간 대신 "생각 요약"으로만 표시합니다.

앱의 스캔은 화면에 넘기기 전에 스캔 스레드에서 `current-scan.json`(1MB 이상 항목)으로 저장합니다. MCP의 `current_scan`과 `list`가 이 파일을 읽어서, 에이전트가 다시 스캔하지 않고 사용자가 보는 트리를 그대로 봅니다. 판정의 출처는 MCP `initialize`의 `clientInfo`로 구분해서, 배너에 "Claude가…"나 "Codex가…"로 표시합니다. 창 기본 크기는 1240×780이고, 사이드바를 열면 최소 너비를 1080으로 올리고 창을 넓힙니다.

시험은 임시 자체 시험 코드(환경 변수로 실제 진입 함수를 순서대로 호출)로 앱 안에서 했고, 커밋 전에 지웠습니다. 두 에이전트 모두 확인한 것: 선택창 → 확인 → 프롬프트가 채워짐 → 보내기, 판정 기록, 휴지통 이동 뒤 차트 동기화, 대화 이어가기, 생각·단계·토큰 기록.

## 2026-10-28 — 에이전트 연동: JSON 내보내기, MCP 서버, Claude 판정 표시 (0.3.0)

- 변경 파일: `Sources/DiskLens/App/Entry.swift`, `Headless/`, `Core/UsageTree.swift`, `Core/Annotations.swift`, `Model/AnnotationCenter.swift`, `Views/ClaudeBanner.swift`와 기존 화면 3개
- 요약: Claude Code의 `storage-cleanup` skill이 DiskLens 엔진을 쓰도록 `--export`(JSON)와 `--mcp`(stdio MCP 서버)를 추가했습니다. Claude가 남긴 판정(`annotations.json`)은 앱의 배너, 목록 배지, 차트 테두리로 보여줍니다.

내보내기와 MCP는 같은 `UsageNode` 트리를 씁니다. 최소 크기보다 작은 항목은 각 폴더의 `otherSize`로 접어 넣기 때문에, 홈 폴더(142만 파일)도 50MB 기준이면 JSON 353KB입니다. MCP 서버는 스캔 결과를 메모리에 두고 `list`와 `largest_files`에 바로 답합니다. `du`를 여러 번 도는 대신 한 번 스캔한 뒤 조회하게 만든 것이 핵심입니다. 화면이 없을 때는 `Scanner.liveSnapshots = false`로 차트용 스냅숏(초당 20회 트리 복사)을 건너뜁니다.

판정을 앱에 넘기는 통로로는 파일(`~/Library/Application Support/DiskLens/annotations.json`)을 골랐습니다. MCP 서버는 Claude Code가 띄우는 별도 프로세스라 앱과 메모리를 공유하지 않고, 파일로 넘기면 MCP 없이 skill이 직접 써도 됩니다. 앱은 2초마다 수정 시각만 확인합니다.

⚠️ **`NSTreatUnknownArgumentsAsOpen`을 지우면 안 됩니다.** AppKit은 경로처럼 생긴 실행 인자를 "열 문서"로 처리하는데, SwiftUI 앱은 실행하면서 문서를 열면 첫 창을 만들지 않습니다. 그래서 README의 `open -a DiskLens --args /folder`는 0.2.0에서도 창 없이 대기만 했습니다. `Entry`에서 이 기본값을 `NO`로 등록해 고쳤습니다.

⚠️ **전체 디스크 접근 권한은 "책임 프로세스"를 따라갑니다.** 터미널에서 바이너리를 직접 실행하면 터미널의 권한으로 스캔합니다. DiskLens 자신의 권한을 쓰려면 `open -n -W -a DiskLens --args --export /abs/path.json <folder>`로 LaunchServices를 거쳐야 하고, 출력 경로는 절대 경로여야 합니다. `--mcp`는 Claude Code가 직접 띄우므로 이 방법을 쓸 수 없습니다. 화면 없이 실행할 때는 `setActivationPolicy(.prohibited)`로 Dock 아이콘이 생기지 않게 했습니다.

`move_to_trash`는 홈 폴더 아래와 `/Applications`만 허용하고, 홈 바로 아래 폴더(`~/Library` 등)는 통째로 옮기지 못하게 막았습니다. 휴지통으로 옮겨도 비우기 전에는 공간이 돌아오지 않는다는 점을 응답에 항상 넣습니다.

시험 중 함정: Claude Code의 백그라운드 세션에서 `open -n`으로 띄운 앱은 창이 뜨지 않았습니다(0.2.0도 같음). 화면이 필요한 확인은 바이너리를 직접 실행해서 해야 합니다. 그 세션에는 화면 기록 권한도 없어서 `screencapture -l`이 실패합니다.
