# 뉴스투데이 섹션 ↔ 봇 연계

저장소: `hjyeagle/newstoday`  
공개 페이지: https://hjyeagle.github.io/newstoday/  
기준일: 2026-09-16

| 번호 | 섹션 | 해시 | 담당 봇 | 연계 |
|------|------|------|---------|------|
| 01 | 내가 출간한 POD(종이책) | `#pod` | POD | 활성 — `bookTitles` + `podLinks` |
| 02 | 내가 출간한 전자책 | `#ebook` | 전자책 | 활성 — `bookTitles` + `ebookLinks` |
| 03 | 사이버 동방예술관 | `#dongbang` | 동방예술관 | 활성 — 소개문·포스터·사이버관 링크 |
| 04 | 비즈넷타임즈 오피니언 기고문 | `#opinion` | 비즈넷타임즈 | 유지 — 현재 `opinionData` 그대로 |
| 05 | 매일 AI와 나눈 이야기 모음 | `#ai-talks` | 노션공유 | 활성 — 선별된 공유만 `aiTalksData`에 유지 (전체 DB 아님) |
| 06 | 자료실 | `#archive` | — | 미연계 |
| 07 | Temp | `#temp` | — | 미연계 |

## 반영 경로

담당 봇이 갱신 사항을 **뉴스투데이** 봇에 넘기면, 뉴스투데이가 `index.html` 데이터 배열을 수정·커밋한다.

## 데이터 위치

모두 `index.html` 하단 스크립트:

- 01/02 공통 제목: `bookTitles`
- 01 링크: `podLinks`
- 02 링크: `ebookLinks`
- 04: `opinionData`
- 05: `aiTalksData`
- 06: `archiveData` (미연계)
- 07: `tempData` (미연계)
