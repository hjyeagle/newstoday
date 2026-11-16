# 뉴스투데이 백업 미러

이 저장소의 GitHub Pages
([https://hjyeagle.github.io/newstoday/](https://hjyeagle.github.io/newstoday/))는
운영 중인 WordPress 사이트 [https://newstoday.co.kr/](https://newstoday.co.kr/) 의
백업·테스트용 정적 미러입니다. 검색엔진이 이 복사본을 수집하지 않도록
모든 HTML에 `noindex,nofollow`를 넣었고, `robots.txt`는 `Disallow: /` 입니다.

정식 사이트 주소는 항상 [https://newstoday.co.kr/](https://newstoday.co.kr/) 입니다.
각 HTML 문서의 `canonical`은 같은 경로의 정식 주소를 가리킵니다.

## 다시 받기

저장소 루트에서 실행합니다.

```bash
bash scripts/mirror-wp.sh
```

GitHub에서는 Actions의 **Mirror WordPress** 워크플로를
`workflow_dispatch`(Run workflow)로 실행합니다. 예약 실행은 없습니다.
스크립트가 사이트를 다시 받은 뒤 워크플로가 변경분을 커밋합니다.

검색, 댓글 등록, 문의·뉴스레터 폼 전송, 로그인, 관리자 화면처럼
서버가 처리하는 기능은 정적 미러에서 동작하지 않습니다.

Cafe24 일일 전송량은 약 4GB입니다. 한도에 가까우면 이 스크립트를 실행하지 마세요.
호스팅은 10분에 약 150회를 넘기면 접속을 막으므로, 스크립트는 요청 간격을 5초 이상으로 둡니다.
2026-11-04(UTC)에는 전송량 한도가 거의 소진되어 받기를 중단했고, 그날은 스크립트가
접속을 거부합니다. 그 이후에는 바뀐 글과 아직 없는 맛집 글을 나누어 받았습니다.
2026-11-16(UTC)에 라이브 사이트의 홈·메뉴·공통 레이아웃을 다시 맞춰 두었습니다.
맛집(`restaurant`) 글 1,557개는 사이트맵과 같고, 본문은 2026-10-21 이후 바뀌지 않았습니다.
