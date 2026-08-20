# UniFinder 랜딩 페이지

정적 HTML/CSS/JS(빌드 없음). 소스는 이 리포지토리 `web/` 아래에서 관리하고, **별도 Vercel 프로젝트**로 배포한다.

## Vercel 프로젝트 설정 (최초 1회, 대시보드에서)

1. Vercel → Add New Project → 이 GitHub 리포지토리(`ilphs/UniFinder`) import
2. **Root Directory**를 `web`으로 지정
3. Framework Preset: **Other**
4. Build Command / Output Directory: 비워둠 (정적 파일 그대로 서빙)

이후 `main` 브랜치의 `web/` 변경 사항이 푸시될 때마다 자동 배포된다.

## 로컬 미리보기

빌드 도구 없이 정적 파일이므로 아무 정적 서버로 열면 된다:

```bash
cd web && python3 -m http.server 8080
```

## 구조

- `index.html` — 단일 페이지. 한국어/영어 텍스트를 `data-ko`/`data-en` 속성에 함께 담아두고 `script.js`가 토글한다 (기본값: 한국어)
- `styles.css`, `script.js`
- `assets/icon.png` — `resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`에서 복사한 앱 아이콘. 아이콘이 바뀌면 다시 복사해야 한다
- `assets/favicon-32.png`, `assets/favicon-16.png` — 브라우저 탭 favicon용으로 `icon.png`을 `sips -z <32|16> <32|16> icon.png --out favicon-<32|16>.png`로 리사이즈한 것. 아이콘 갱신 시 함께 재생성

## 유지보수 시 주의

- 다운로드 버튼은 특정 dmg 파일명이 아니라 `/releases/latest`로 링크한다 — 버전마다 파일명이 바뀌므로(`UniFinder-X.Y.Z-macOS.dmg`) 하드코딩하지 않는다. `script.js`가 최신 릴리스 자산 중 `/\.dmg$/i`로 찾는다 — 배포 포맷을 바꾸면 이 정규식도 함께 바꿔야 한다(2026-08-20 zip → dmg 전환 때 실제로 놓치기 쉬운 지점이었다)
- 버전 표시(`#version-tag`)는 하드코딩이 아니라 `script.js`가 GitHub Releases API(`/repos/ilphs/UniFinder/releases/latest`)에서 `tag_name`을 가져와 채운다. `index.html`의 `v0.5.0`은 스크립트가 로드되기 전(또는 API 실패 시)에만 보이는 기본값이므로, 릴리스할 때마다 갱신할 필요는 없지만 너무 오래 방치하지 않는 게 좋다
- quarantine 안내 문구는 [`README.md`](../README.md) · [`INSTALL.md`](../INSTALL.md)와 동기화 — 절차가 바뀌면 함께 확인
