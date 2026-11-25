// First run, and the apps your agents use.
//
// The welcome is four steps over the whole window: meet the crew, sign in with
// Enkeon (a code you confirm in the browser; pick which brain they remember
// into), connect the apps they work with, then hire. Every step can be
// skipped; Cookie works without an account, with less. It shows once.
//
// The apps panel is the same in the welcome and in Settings → Enkeon: each app
// with its real state in Enkeon, one click to connect (its own sign-in opens
// in the browser; Cookie finishes the connect itself and the tile turns live).

const APP_LOGOS = {"gmail": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSI+CiAgCiAgPHBhdGggZmlsbD0iI0VBNDMzNSIgZD0iTTggMTAuMnYxMS42aDIuNFYxNC44bDMuNiAyLjcgMy42LTIuN3Y3aDIuNFYxMC4yTDE2IDE1LjEgOCAxMC4yeiIvPgogIDxwYXRoIGZpbGw9IiM0Mjg1RjQiIGQ9Ik0yMiAxMC4ydjExLjZoMi40Yy43IDAgMS4yLS41IDEuMi0xLjJWMTIuMWMwLTEuNi0xLjctMi42LTMtMS42TDIyIDExLjR2LTEuMnoiLz4KICA8cGF0aCBmaWxsPSIjMzRBODUzIiBkPSJNNi40IDIxLjhWMTIuMWMwLS43LjUtMS4yIDEuMi0xLjJIOHYxMC45SDYuNHoiLz4KICA8cGF0aCBmaWxsPSIjQzUyMjFGIiBkPSJNMjIgMjEuOGgxLjZjLjcgMCAxLjItLjUgMS4yLTEuMnYtLjZIMjJ2MS44eiIvPgo8L3N2Zz4K", "google_calendar": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48cGF0aCBmaWxsPSIjZmZmIiBkPSJNMTk1LjM2OCA2MC42MzJINjAuNjMydjEzNC43MzZoMTM0LjczNnoiLz48cGF0aCBmaWxsPSIjZWE0MzM1IiBkPSJNMTk1LjM2OCAyNTZMMjU2IDE5NS4zNjhsLTMwLjMxNi01LjE3MmwtMzAuMzE2IDUuMTcybC01LjUzMyAyNy43M3oiLz48cGF0aCBmaWxsPSIjMTg4MDM4IiBkPSJNMCAxOTUuMzY4djQwLjQyMUMwIDI0Ni45NTYgOS4wNDQgMjU2IDIwLjIxIDI1Nmg0MC40MjJsNi4yMjUtMzAuMzE2bC02LjIyNS0zMC4zMTZsLTMzLjAzMy01LjE3MnoiLz48cGF0aCBmaWxsPSIjMTk2N2QyIiBkPSJNMjU2IDYwLjYzMlYyMC4yMUMyNTYgOS4wNDQgMjQ2Ljk1NiAwIDIzNS43OSAwaC00MC40MjJxLTUuNTMyIDIyLjU1NC01LjUzMyAzMy4xOTZxMCAxMC42NDEgNS41MzMgMjcuNDM2cTIwLjExNSA1Ljc2IDMwLjMxNiA1Ljc2VDI1NiA2MC42MzEiLz48cGF0aCBmaWxsPSIjZmJiYzA0IiBkPSJNMjU2IDYwLjYzMmgtNjAuNjMydjEzNC43MzZIMjU2eiIvPjxwYXRoIGZpbGw9IiMzNGE4NTMiIGQ9Ik0xOTUuMzY4IDE5NS4zNjhINjAuNjMyVjI1NmgxMzQuNzM2eiIvPjxwYXRoIGZpbGw9IiM0Mjg1ZjQiIGQ9Ik0xOTUuMzY4IDBIMjAuMjExQzkuMDQ0IDAgMCA5LjA0NCAwIDIwLjIxdjE3NS4xNThoNjAuNjMyVjYwLjYzMmgxMzQuNzM2eiIvPjxwYXRoIGZpbGw9IiM0Mjg1ZjQiIGQ9Ik04OC4yNyAxNjUuMTU0Yy01LjAzNi0zLjQwMi04LjUyMy04LjM3LTEwLjQyNi0xNC45NGwxMS42ODktNC44MTZxMS41OSA2LjA2MyA1LjU1OCA5LjM5OGMyLjYyNyAyLjIyMyA1LjgyNyAzLjMxOCA5LjU2NiAzLjMxOHE1LjczNCAwIDkuODUyLTMuNDg3YzIuNzQ2LTIuMzI0IDQuMTI3LTUuMjg4IDQuMTI3LTguODc1cTAtNS41MDgtNC4zNDUtOC45OTRjLTIuODk3LTIuMzI0LTYuNTM1LTMuNDg2LTEwLjg4LTMuNDg2aC02Ljc1NHYtMTEuNTdoNi4wNjNxNS42MDggMCA5LjQ0OC0zLjAzM2MyLjU2LTIuMDIgMy44NC00Ljc4MyAzLjg0LTguMzAzYzAtMy4xMzItMS4xNDUtNS42MjUtMy40MzUtNy40OTRjLTIuMjktMS44Ny01LjE4OC0yLjgxMy04LjcwOC0yLjgxM2MtMy40MzYgMC02LjE2NC45MS04LjE4NSAyLjc0NWExNi4xIDE2LjEgMCAwIDAtNC40MTMgNi43NTRsLTExLjU3LTQuODE3YzEuNTMyLTQuMzQ1IDQuMzQ1LTguMTg1IDguNDcxLTExLjUwM3M5LjM5OC00Ljk4NSAxNS43OTgtNC45ODVjNC43MzMgMCA4Ljk5NC45MSAxMi43NjcgMi43NDVjMy43NzIgMS44MzYgNi43MzYgNC4zNzkgOC44NzUgNy42MTNjMi4xNCAzLjI1IDMuMiA2Ljg4OCAzLjIgMTAuOTNjMCA0LjEyNi0uOTkzIDcuNjEzLTIuOTggMTAuNDc2cy00LjQzIDUuMDUyLTcuMzI3IDYuNTg1di42OWEyMi4yNSAyMi4yNSAwIDAgMSA5LjM5OCA3LjMyN2MyLjQ0MiAzLjI4NCAzLjY3MiA3LjIwOCAzLjY3MiAxMS43OWMwIDQuNTgtMS4xNjMgOC42NzMtMy40ODcgMTIuMjZjLTIuMzI0IDMuNTg4LTUuNTQgNi40MTctOS42MTcgOC40NzJjLTQuMDkyIDIuMDU1LTguNjkgMy4xLTEzLjc5MyAzLjFjLTUuOTEyLjAxNi0xMS4zNjktMS42ODUtMTYuNDA1LTUuMDg3bTcxLjc5Ny01OC4wMDVsLTEyLjgzMyA5LjI4bC02LjQxNy05LjczNGwyMy4wMjMtMTYuNjA3aDguODI1djc4LjMzM2gtMTIuNTk4eiIvPjwvc3ZnPg==", "slack": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSI+CiAgCiAgPHBhdGggZmlsbD0iI0UwMUU1QSIgZD0iTTEzLjEgMTguOWExLjg1IDEuODUgMCAwIDEtMS44NSAxLjg1IDEuODUgMS44NSAwIDAgMS0xLjg1LTEuODVjMC0xLjAyLjgzLTEuODUgMS44NS0xLjg1aDEuODV2MS44NXoiLz4KICA8cGF0aCBmaWxsPSIjRTAxRTVBIiBkPSJNMTQuMDUgMTguOWMwLTEuMDIuODMtMS44NSAxLjg1LTEuODVzMS44NS44MyAxLjg1IDEuODV2NC41NWExLjg1IDEuODUgMCAwIDEtMy43IDBWMTguOXoiLz4KICA8cGF0aCBmaWxsPSIjMzZDNUYwIiBkPSJNMTUuOSAxMy4xYTEuODUgMS44NSAwIDAgMS0xLjg1LTEuODVjMC0xLjAyLjgzLTEuODUgMS44NS0xLjg1czEuODUuODMgMS44NSAxLjg1djEuODVIMTUuOXoiLz4KICA8cGF0aCBmaWxsPSIjMzZDNUYwIiBkPSJNMTUuOSAxNC4wNWMxLjAyIDAgMS44NS44MyAxLjg1IDEuODVzLS44MyAxLjg1LTEuODUgMS44NUgxMS4zNWExLjg1IDEuODUgMCAwIDEgMC0zLjdIMTUuOXoiLz4KICA8cGF0aCBmaWxsPSIjMkVCNjdEIiBkPSJNMjEuNyAxNS45YTEuODUgMS44NSAwIDAgMSAxLjg1LTEuODVjMS4wMiAwIDEuODUuODMgMS44NSAxLjg1cy0uODMgMS44NS0xLjg1IDEuODVIMjEuN1YxNS45eiIvPgogIDxwYXRoIGZpbGw9IiMyRUI2N0QiIGQ9Ik0yMC43NSAxNS45YzAgMS4wMi0uODMgMS44NS0xLjg1IDEuODVzLTEuODUtLjgzLTEuODUtMS44NVYxMS4zNWExLjg1IDEuODUgMCAwIDEgMy43IDBWMTUuOXoiLz4KICA8cGF0aCBmaWxsPSIjRUNCMjJFIiBkPSJNMTguOSAyMS43YTEuODUgMS44NSAwIDAgMSAxLjg1IDEuODVjMCAxLjAyLS44MyAxLjg1LTEuODUgMS44NXMtMS44NS0uODMtMS44NS0xLjg1VjIxLjdIMTguOXoiLz4KICA8cGF0aCBmaWxsPSIjRUNCMjJFIiBkPSJNMTguOSAyMC43NWMtMS4wMiAwLTEuODUtLjgzLTEuODUtMS44NXMuODMtMS44NSAxLjg1LTEuODVoNC41NWExLjg1IDEuODUgMCAwIDEgMCAzLjdIMTguOXoiLz4KPC9zdmc+Cg==", "google_drive": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjI5Ij48cGF0aCBmaWxsPSIjMDA2NmRhIiBkPSJtMTkuMzU0IDE5Ni4wMzRsMTEuMjkgMTkuNWMyLjM0NiA0LjEwNiA1LjcxOCA3LjMzMiA5LjY3NyA5LjY3OHExNy4wMDktMjEuNTkxIDIzLjY4LTMzLjEzN3E2Ljc3LTExLjcxNyAxNi42NDEtMzYuNjU1cS0yNi42MDQtMy41MDItNDAuMzItMy41MDJxLTEzLjE2NSAwLTQwLjMyMiAzLjUwMmMwIDQuNTQ1IDEuMTczIDkuMDkgMy41MTkgMTMuMTk2eiIvPjxwYXRoIGZpbGw9IiNlYTQzMzUiIGQ9Ik0yMTUuNjgxIDIyNS4yMTJjMy45Ni0yLjM0NiA3LjMzMi01LjU3MiA5LjY3Ny05LjY3N2w0LjY5Mi04LjA2NGwyMi40MzQtMzguODU1YTI2LjU3IDI2LjU3IDAgMCAwIDMuNTE4LTEzLjE5NnEtMjcuMzE1LTMuNTAyLTQwLjI0Ny0zLjUwMnEtMTMuODk5IDAtNDAuMjQ4IDMuNTAycTkuNzU0IDI1LjA3NSAxNi40MjIgMzYuNjU1cTYuNzI0IDExLjY4MyAyMy43NTIgMzMuMTM3Ii8+PHBhdGggZmlsbD0iIzAwODMyZCIgZD0iTTEyOC4wMDEgNzMuMzExcTE5LjY4LTIzLjc2OCAyNy4xMjUtMzYuNjU1cTUuOTk2LTEwLjM3NyAxMy4xOTYtMzMuMTM3QzE2NC4zNjMgMS4xNzMgMTU5LjgxOCAwIDE1NS4xMjYgMGgtNTQuMjVDOTYuMTg0IDAgOTEuNjQgMS4zMiA4Ny42OCAzLjUxOXE5LjE2IDI2LjEwMyAxNS41NDQgMzcuMTU0cTcuMDU2IDEyLjIxMyAyNC43NzcgMzIuNjM4Ii8+PHBhdGggZmlsbD0iIzI2ODRmYyIgZD0iTTE3NS4zNiAxNTUuNDJIODAuNjQybC00MC4zMiA2OS43OTJjMy45NTggMi4zNDYgOC41MDMgMy41MTkgMTMuMTk1IDMuNTE5aDE0OC45NjhjNC42OTIgMCA5LjIzOC0xLjMyIDEzLjE5Ni0zLjUyeiIvPjxwYXRoIGZpbGw9IiMwMGFjNDciIGQ9Ik0xMjguMDAxIDczLjMxMUw4Ny42ODEgMy41MmMtMy45NiAyLjM0Ni03LjMzMiA1LjU3MS05LjY3OCA5LjY3N0wzLjUxOSAxNDIuMjI0QTI2LjU3IDI2LjU3IDAgMCAwIDAgMTU1LjQyaDgwLjY0MnoiLz48cGF0aCBmaWxsPSIjZmZiYTAwIiBkPSJtMjE1LjI0MiA3Ny43MWwtMzcuMjQzLTY0LjUxNGMtMi4zNDUtNC4xMDYtNS43MTgtNy4zMzEtOS42NzctOS42NzdsLTQwLjMyIDY5Ljc5Mmw0Ny4zNTggODIuMTA5aDgwLjQ5NmMwLTQuNTQ2LTEuMTczLTkuMDktMy41MTktMTMuMTk2eiIvPjwvc3ZnPg==", "notion": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSI+CiAgCiAgPHBhdGggZmlsbD0iIzE5MTkxOSIgZD0iTTEwLjIgOC40Yy41LjQuNy40IDEuNi4zbDguOC0uNWMuMiAwIDAtLjIgMC0uMmwtMS41LTEuMmMtLjMtLjItLjctLjUtMS40LS40bC04LjUuN2MtLjMgMC0uNC4yLS4yLjN6bS41IDJ2OS4xYzAgLjUuMi42LjcuOGwyLjEuNmMuNS4xLjcgMCAuNy0uNFYxMS4yYzAtLjQuMi0uNi41LS42bDIuOS0uMmMuNCAwIC41LjIuNS42djkuM2MwIC41LjEuNy43LjRsMi4yLTFjLjQtLjIuNS0uNC41LS44VjEwLjJjMC0uNC0uMS0uNy0uNy0uNmwtOS4xLjZjLS41IDAtLjcuMi0uNy42eiIvPgo8L3N2Zz4K", "github": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSI+CiAgCiAgPHBhdGggZmlsbD0iIzE4MTcxNyIgZD0iTTE2IDYuNWMtNS4yIDAtOS41IDQuMy05LjUgOS41IDAgNC4yIDIuNyA3LjcgNi41IDkgLjUuMS42LS4yLjYtLjV2LTEuNmMtMi42LjYtMy4yLTEuMy0zLjItMS4zLS40LTEuMS0xLjEtMS40LTEuMS0xLjQtLjktLjYuMS0uNi4xLS42IDEgMCAxLjUgMSAxLjUgMSAuOSAxLjUgMi4zIDEuMSAyLjguOC4xLS42LjMtMSAuNi0xLjMtMi4xLS4yLTQuMy0xLjEtNC4zLTQuNyAwLTEgLjQtMS45IDEtMi41LS4xLS4zLS40LTEuMy4xLTIuNiAwIDAgLjgtLjMgMi42IDEgLjgtLjIgMS42LS4zIDIuNC0uM3MxLjYuMSAyLjQuM2MxLjgtMS4yIDIuNi0xIDIuNi0xIC41IDEuMy4yIDIuMy4xIDIuNi42LjcgMSAxLjUgMSAyLjUgMCAzLjYtMi4yIDQuNC00LjMgNC43LjMuMy42LjguNiAxLjd2Mi41YzAgLjMuMi42LjYuNSAzLjgtMS4zIDYuNS00LjggNi41LTkgMC01LjItNC4zLTkuNS05LjUtOS41eiIvPgo8L3N2Zz4K", "outlook": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iIzAwNzhENCIgZD0iTTcuODggMTIuMDRxMCAuNDUtLjExLjg3cS0uMS40MS0uMzMuNzRxLS4yMi4zMy0uNTguNTJxLS4zNy4yLS44Ny4ydC0uODUtLjJxLS4zNS0uMjEtLjU3LS41NXEtLjIyLS4zMy0uMzMtLjc1cS0uMS0uNDItLjEtLjg2dC4xLS44N3QuMzQtLjc2cS4yMi0uMzQuNTktLjU0cS4zNi0uMi44Ny0uMnQuODYuMnEuMzUuMjEuNTcuNTV0LjMxLjc3cS4xLjQzLjEuODhNMjQgMTJ2OS4zOHEwIC40Ni0uMzMuOHEtLjMzLjMyLS44LjMySDcuMTNxLS40NiAwLS44LS4zM3EtLjMyLS4zMy0uMzItLjhWMThIMXEtLjQxIDAtLjctLjNxLS4zLS4yOS0uMy0uN1Y3cTAtLjQxLjMtLjdRLjU4IDYgMSA2aDYuNVYyLjU1cTAtLjQ0LjMtLjc1cS4zLS4zLjc1LS4zaDEyLjlxLjQ0IDAgLjc1LjNxLjMuMy4zLjc1djguM2wxLjI0LjcyaC4wMXEuMS4wNy4xOC4xOHEuMDcuMTIuMDcuMjVtLTYtOC4yNXYzaDN2LTN6bTAgNC41djNoM3YtM3ptMCA0LjV2MS44M2wzLjA1LTEuODN6bS01LjI1LTl2M2gzLjc1di0zem0wIDQuNXYzaDMuNzV2LTN6bTAgNC41djIuMDNsMi40MSAxLjVsMS4zNC0uOHYtMi43M3pNOSAzLjc1VjZoMmwuMTMuMDFsLjEyLjA0di0yLjN6TTUuOTggMTUuOThxLjkgMCAxLjYtLjNxLjctLjMyIDEuMTktLjg2cS40OC0uNTUuNzMtMS4yOHEuMjUtLjc0LjI1LTEuNjFxMC0uODMtLjI1LTEuNTVxLS4yNC0uNzEtLjcxLTEuMjR0LTEuMTUtLjgzdC0xLjU1LS4zcS0uOTIgMC0xLjY0LjNxLS43MS4zLTEuMi44NXEtLjUuNTQtLjc1IDEuM3EtLjI1Ljc0LS4yNSAxLjYzcTAgLjg1LjI2IDEuNTZxLjI2LjcyLjc0IDEuMjNxLjQ4LjUyIDEuMTcuODFxLjY5LjMgMS41Ni4zek03LjUgMjFoMTIuMzlMMTIgMTYuMDhWMTdxMCAuNDEtLjMuN3EtLjI5LjMtLjcuM0g3LjV6bTE1LS4xM3YtNy4yNGwtNS45IDMuNTRaIi8+PC9zdmc+", "linear": "data:image/svg+xml;base64,PHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+TGluZWFyPC90aXRsZT48cGF0aCBmaWxsPSIjNUU2QUQyIiBkPSJNMi44ODYgNC4xOEExMS45ODIgMTEuOTgyIDAgMCAxIDExLjk5IDBDMTguNjI0IDAgMjQgNS4zNzYgMjQgMTIuMDA5YzAgMy42NC0xLjYyIDYuOTAzLTQuMTggOS4xMDVMMi44ODcgNC4xOFpNMS44MTcgNS42MjZsMTYuNTU2IDE2LjU1NmMtLjUyNC4zMy0xLjA3NS42Mi0xLjY1Ljg2NkwuOTUxIDcuMjc3Yy4yNDctLjU3NS41MzctMS4xMjYuODY2LTEuNjVaTS4zMjIgOS4xNjNsMTQuNTE1IDE0LjUxNWMtLjcxLjE3Mi0xLjQ0My4yODItMi4xOTUuMzIyTDAgMTEuMzU4YTEyIDEyIDAgMCAxIC4zMjItMi4xOTVabS0uMTcgNC44NjIgOS44MjMgOS44MjRhMTIuMDIgMTIuMDIgMCAwIDEtOS44MjQtOS44MjRaIi8+PC9zdmc+", "google_sheets": "data:image/svg+xml;base64,PHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+R29vZ2xlIFNoZWV0czwvdGl0bGU+PHBhdGggZmlsbD0iIzM0QTg1MyIgZD0iTTExLjMxOCAxMi41NDVINy45MXYtMS45MDloMy40MXYxLjkxek0xNC43MjggMHY2aDZsLTYtNnptMS4zNjMgMTAuNjM2aC0zLjQxdjEuOTFoMy40MXYtMS45MXptMCAzLjI3M2gtMy40MXYxLjkxaDMuNDF2LTEuOTF6TTIwLjcyNyA2LjV2MTUuODY0YzAgLjkwNC0uNzMyIDEuNjM2LTEuNjM2IDEuNjM2SDQuOTA5YTEuNjM2IDEuNjM2IDAgMCAxLTEuNjM2LTEuNjM2VjEuNjM2QzMuMjczLjczMiA0LjAwNSAwIDQuOTA5IDBoOS4zMTh2Ni41aDYuNXptLTMuMjczIDIuNzczSDYuNTQ1djcuOTA5aDEwLjkxdi03Ljkxem0tNi4xMzYgNC42MzZINy45MXYxLjkxaDMuNDF2LTEuOTF6Ii8+PC9zdmc+", "hubspot": "data:image/svg+xml;base64,PHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+SHViU3BvdDwvdGl0bGU+PHBhdGggZmlsbD0iI0ZGN0E1OSIgZD0iTTE4LjE2NCA3LjkzVjUuMDg0YTIuMTk4IDIuMTk4IDAgMDAxLjI2Ny0xLjk3OHYtLjA2N0EyLjIgMi4yIDAgMDAxNy4yMzguODQ1aC0uMDY3YTIuMiAyLjIgMCAwMC0yLjE5MyAyLjE5M3YuMDY3YTIuMTk2IDIuMTk2IDAgMDAxLjI1MiAxLjk3M2wuMDEzLjAwNnYyLjg1MmE2LjIyIDYuMjIgMCAwMC0yLjk2OSAxLjMxbC4wMTItLjAxLTcuODI4LTYuMDk1QTIuNDk3IDIuNDk3IDAgMTA0LjMgNC42NTZsLS4wMTIuMDA2IDcuNjk3IDUuOTkxYTYuMTc2IDYuMTc2IDAgMDAtMS4wMzggMy40NDZjMCAxLjM0My40MjUgMi41ODggMS4xNDcgMy42MDdsLS4wMTMtLjAyLTIuMzQyIDIuMzQzYTEuOTY4IDEuOTY4IDAgMDAtLjU4LS4wOTVoLS4wMDJhMi4wMzMgMi4wMzMgMCAxMDIuMDMzIDIuMDMzIDEuOTc4IDEuOTc4IDAgMDAtLjEtLjU5NWwuMDA1LjAxNCAyLjMxNy0yLjMxN2E2LjI0NyA2LjI0NyAwIDEwNC43ODItMTEuMTM0bC0uMDM2LS4wMDV6bS0uOTY0IDkuMzc4YTMuMjA2IDMuMjA2IDAgMTEzLjIxNS0zLjIwN3YuMDAyYTMuMjA2IDMuMjA2IDAgMDEtMy4yMDcgMy4yMDd6Ii8+PC9zdmc+", "jira": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9IlNWR1NCSTdvYmFDIiB4MT0iOTguMDMxJSIgeDI9IjU4Ljg4OCUiIHkxPSIuMTYxJSIgeTI9IjQwLjc2NiUiPjxzdG9wIG9mZnNldD0iMTglIiBzdG9wLWNvbG9yPSIjMDA1MmNjIi8+PHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMjY4NGZmIi8+PC9saW5lYXJHcmFkaWVudD48bGluZWFyR3JhZGllbnQgaWQ9IlNWR0hpZlpsYnpFIiB4MT0iMTAwLjY2NSUiIHgyPSI1NS40MDIlIiB5MT0iLjQ1NSUiIHkyPSI0NC43MjclIj48c3RvcCBvZmZzZXQ9IjE4JSIgc3RvcC1jb2xvcj0iIzAwNTJjYyIvPjxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzI2ODRmZiIvPjwvbGluZWFyR3JhZGllbnQ+PC9kZWZzPjxwYXRoIGZpbGw9IiMyNjg0ZmYiIGQ9Ik0yNDQuNjU4IDBIMTIxLjcwN2E1NS41IDU1LjUgMCAwIDAgNTUuNTAyIDU1LjUwMmgyMi42NDlWNzcuMzdjLjAyIDMwLjYyNSAyNC44NDEgNTUuNDQ3IDU1LjQ2NiA1NS40NjdWMTAuNjY2QzI1NS4zMjQgNC43NzcgMjUwLjU1IDAgMjQ0LjY1OCAwIi8+PHBhdGggZmlsbD0idXJsKCNTVkdTQkk3b2JhQykiIGQ9Ik0xODMuODIyIDYxLjI2Mkg2MC44NzJjLjAxOSAzMC42MjUgMjQuODQgNTUuNDQ3IDU1LjQ2NiA1NS40NjdoMjIuNjQ5djIxLjkzOGMuMDM5IDMwLjYyNSAyNC44NzcgNTUuNDMgNTUuNTAyIDU1LjQzVjcxLjkzYzAtNS44OTEtNC43NzYtMTAuNjY3LTEwLjY2Ny0xMC42NjciLz48cGF0aCBmaWxsPSJ1cmwoI1NWR0hpZlpsYnpFKSIgZD0iTTEyMi45NTEgMTIyLjQ4OUgwYzAgMzAuNjUzIDI0Ljg1IDU1LjUwMiA1NS41MDIgNTUuNTAyaDIyLjcydjIxLjg2N2MuMDIgMzAuNTk3IDI0Ljc5OCA1NS40MDggNTUuMzk2IDU1LjQ2NlYxMzMuMTU2YzAtNS44OTEtNC43NzYtMTAuNjY3LTEwLjY2Ny0xMC42NjciLz48L3N2Zz4=", "zoom": "data:image/svg+xml;base64,PHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+Wm9vbTwvdGl0bGU+PHBhdGggZmlsbD0iIzBCNUNGRiIgZD0iTTUuMDMzIDE0LjY0OUguNzQzYS43NC43NCAwIDAgMS0uNjg2LS40NTguNzQuNzQgMCAwIDEgLjE2LS44MDhMMy4xOSAxMC40MUgxLjA2QTEuMDYgMS4wNiAwIDAgMSAwIDkuMzVoMy45NTdjLjMwMSAwIC41Ny4xOC42ODYuNDU4YS43NC43NCAwIDAgMS0uMTYxLjgwOEwxLjUxIDEzLjU5aDIuNDY0Yy41ODUgMCAxLjA2LjQ3NSAxLjA2IDEuMDZ6TTI0IDExLjMzOGMwLTEuMTQtLjkyNy0yLjA2Ni0yLjA2Ni0yLjA2Ni0uNjEgMC0xLjE1OC4yNjUtMS41MzcuNjg2YTIuMDYxIDIuMDYxIDAgMCAwLTEuNTM2LS42ODZjLTEuMTQgMC0yLjA2Ni45MjYtMi4wNjYgMi4wNjZ2My4zMTFhMS4wNiAxLjA2IDAgMCAwIDEuMDYtMS4wNnYtMi4yNTFhMS4wMDQgMS4wMDQgMCAwIDEgMi4wMTMgMHYyLjI1MWMwIC41ODYuNDc0IDEuMDYgMS4wNiAxLjA2di0zLjMxMWExLjAwNCAxLjAwNCAwIDAgMSAyLjAxMiAwdjIuMjUxYzAgLjU4Ni40NzUgMS4wNiAxLjA2IDEuMDZ6TTE2LjI2NSAxMmEyLjcyOCAyLjcyOCAwIDEgMS01LjQ1NyAwIDIuNzI4IDIuNzI4IDAgMCAxIDUuNDU3IDB6bS0xLjA2IDBhMS42NjkgMS42NjkgMCAxIDAtMy4zMzggMCAxLjY2OSAxLjY2OSAwIDAgMCAzLjMzOCAwem0tNC44MiAwYTIuNzI4IDIuNzI4IDAgMSAxLTUuNDU4IDAgMi43MjggMi43MjggMCAwIDEgNS40NTcgMHptLTEuMDYgMGExLjY2OSAxLjY2OSAwIDEgMC0zLjMzOCAwIDEuNjY5IDEuNjY5IDAgMCAwIDMuMzM4IDB6Ii8+PC9zdmc+"};
const WELCOMED = "cookie.welcomed";
let welcomeFaces = [], welcomeTimers = [], appsTimer = null;

function welcomeClear() {
  welcomeFaces.forEach((f) => f.stop()); welcomeFaces = [];
  welcomeTimers.forEach(clearTimeout); welcomeTimers = [];
  clearTimeout(appsTimer); appsTimer = null;
}

/** Cookie is used signed in with Enkeon: until this Mac is, the welcome stands in front.
 *  A first launch starts at meeting the crew; anyone who has been here before, at signing in. */
async function maybeWelcome() {
  let st = null;
  try { st = await call("enkeon"); } catch {}
  if (st?.paired) { try { localStorage.setItem(WELCOMED, "1"); } catch {} return false; }
  let seen = false;
  try { seen = !!localStorage.getItem(WELCOMED); } catch {}
  openWelcome(seen || rows.some((r) => r.id !== "cookie") ? "signin" : "hello");
  return true;
}

function openWelcome(step = "hello") {
  let w = $("welcome");
  if (!w) {
    w = el("div", "welcome");
    w.id = "welcome";
    w.setAttribute("role", "dialog");
    w.setAttribute("aria-modal", "true");
    w.setAttribute("aria-label", "Welcome to Cookie");
    document.body.append(w);
  }
  w.hidden = false;
  welcomeStep(step);
}

function closeWelcome(then) {
  welcomeClear();
  try { localStorage.setItem(WELCOMED, "1"); } catch {}
  const w = $("welcome");
  if (w) { w.classList.add("leaving"); setTimeout(() => { w.remove(); then?.(); }, 380); }
  else then?.();
}

const STEPS = ["hello", "signin", "apps", "hire"];

function welcomeFrame(step, ...content) {
  const w = $("welcome");
  const dots = el("div", "wl-dots");
  dots.setAttribute("aria-hidden", "true");
  STEPS.forEach((s, i) => dots.append(el("i", s === step ? "on" : STEPS.indexOf(step) > i ? "done" : "")));
  const card = el("div", "wl-card");
  card.append(...content);
  w.replaceChildren(el("div", "wl-aurora"), dots, card);
}

async function welcomeStep(step) {
  welcomeClear();
  if (step === "hello") return welcomeHello();
  if (step === "signin") return welcomeSignin();
  if (step === "apps") return welcomeApps();
  // Done: a new team hires; a team that already has agents goes back to them.
  closeWelcome(async () => {
    providers = await call("providers").catch(() => providers);
    const team = rows.filter((r) => r.id !== "cookie");
    if (team.length) { sortRows(); openAgent((rows.find((r) => needsOf(r.id).count > 0) ?? rows[0]).id); }
    else openHire();
  });
}

/* ---------- 1. meet the crew ---------- */
function welcomeHello() {
  const crew = el("div", "wl-crew");
  const shapes = ["bot", "orb", "wisp", "crystal", "star", "ghost", "cloud"];
  const tricks = [["corkscrew", 0.5], ["spin2", 0.4], ["front", 0.46], ["back", 0.46]];
  shapes.forEach((shape, i) => {
    const big = i === 3;
    const f = Faces.create(Faces.idFor("welcome", shape), big ? 104 : 72, undefined, { view: 2.4 });
    welcomeFaces.push(f);
    const slot = el("div", "wl-slot" + (big ? " big" : ""));
    slot.style.setProperty("--i", i);
    slot.append(f.el);
    crew.append(slot);
    // Each arrives with a hop, then does a trick now and then.
    welcomeTimers.push(setTimeout(() => { f.jump(0.3, 620); f.fx("sparkle"); }, 260 + i * 110));
    const loop = () => {
      const [roll, h] = tricks[Math.floor(Math.random() * tricks.length)];
      f.jump(h, 1000); setTimeout(() => f.flip(roll, 600), 200);
      if (Math.random() < 0.4) f.fx(Math.random() < 0.5 ? "wind" : "stardust", 900);
      welcomeTimers.push(setTimeout(loop, 3200 + Math.random() * 4200));
    };
    welcomeTimers.push(setTimeout(loop, 1800 + i * 700 + Math.random() * 1500));
  });
  const go = button("Sign in with Enkeon", "primary wl-go", () => welcomeStep("signin"));
  welcomeFrame("hello",
    crew,
    el("h1", "wl-title", "Beyond assistants."),
    el("p", "wl-tag", "Agents that grow up."),
    el("p", "wl-sub", "A team of agents on your Mac, each with its own job, memory and face. They learn from every job, work while you sleep, and ask before anything that matters."),
    box("div", "wl-actions", go),
  );
  setTimeout(() => go.focus(), 50);
}

/* ---------- 2. sign in, pick the brain ---------- */
async function welcomeSignin() {
  const status = el("div", "wl-status");
  const face = Faces.create(Faces.idFor("welcome", "orb"), 88, undefined, { view: 2.4 });
  welcomeFaces.push(face);
  face.setMood("thinking");
  welcomeFrame("signin",
    box("div", "wl-hero", face.el),
    el("h1", "wl-title sm", "Sign in with Enkeon"),
    el("p", "wl-sub", "Your agents remember into an Enkeon brain, with proof for every memory, and reach your apps through it. Cookie keeps its own key for this Mac in your Keychain; your password never comes here."),
    status,
    el("p", "wl-fine", "Cookie works signed in, so every agent has a memory with proof and your apps from the first job."),
  );
  let started = false;
  const tick = async () => {
    if (!$("welcome")) return;
    let st;
    try { st = await call("enkeon"); } catch (e) { status.replaceChildren(el("p", "error-line", String(e))); return; }
    const p = st.pairing;
    if (st.paired) {
      face.setMood("done");
      face.fx("sparkle");
      status.replaceChildren(box("div", "wl-ok", icon("check"), el("span", null, `Signed in. Your agents remember into “${st.paired.project_name}”.`)));
      welcomeTimers.push(setTimeout(() => welcomeStep("apps"), 1300));
      return;
    }
    if (!p || ["failed", "expired", "denied"].includes(p.state)) {
      if (started && p) status.replaceChildren(el("p", "error-line", p.error || PAIR_WORDS[p.state] || "The sign-in didn't finish."));
      const again = button(started ? "Try again" : "Open the sign-in", "primary wl-go", async () => {
        const r = await call("pair_start");
        started = true;
        if (r.url) await Api.openUrl(r.url).catch(() => {});
        tick();
      });
      status.append(again);
      if (!started) { started = true; again.click(); }
      return;
    }
    if (p.state === "waiting") {
      const code = el("div", "wl-code");
      for (const ch of p.user_code) code.append(el("span", ch === "-" ? "dash" : "", ch));
      status.replaceChildren(code, el("p", "wl-hint", "Confirm this code in the browser window that opened."), button("Open the browser again", "quiet small", () => Api.openUrl(p.url).catch(() => {})));
    } else if (p.state === "choose") {
      face.setMood("idle");
      const list = el("div", "wl-brains");
      for (const proj of p.projects) {
        const b = el("button", "wl-brain");
        b.type = "button";
        b.append(el("span", "wl-brain-dot"), el("span", null, proj.name));
        b.onclick = async () => {
          b.disabled = true;
          try { await call("pair_choose", { project: proj.id }); tick(); }
          catch (e) { toast("Couldn't use that brain", String(e), "error"); b.disabled = false; }
        };
        list.append(b);
      }
      status.replaceChildren(el("p", "wl-hint", "Which brain should your agents remember into?"), list);
      return; // waits for a click
    }
    welcomeTimers.push(setTimeout(tick, 2000));
  };
  tick();
}

/* ---------- 3. the apps they work with ---------- */
function welcomeApps() {
  const grid = el("div", "apps-grid");
  welcomeFrame("apps",
    el("h1", "wl-title sm", "Connect the apps they work with"),
    el("p", "wl-sub", "Enkeon keeps the accounts and syncs them into your brain, so every agent can use them. Each app signs in on its own page; nothing is sent without your yes."),
    grid,
    box("div", "wl-actions", button("Continue", "primary wl-go", () => welcomeStep("hire")), button("Later", "quiet wl-skip", () => welcomeStep("hire"))),
  );
  renderApps(grid);
}

/** The apps, live: each tile its logo, its state, one click to connect. Polls while open. */
async function renderApps(grid) {
  clearTimeout(appsTimer);
  if (!grid.isConnected) return;
  let st;
  try { st = await call("apps"); } catch (e) { grid.replaceChildren(el("p", "error-line", String(e))); return; }
  const tiles = [];
  if (!st.signed_in && st.paired) {
    // Managing apps takes your account sign-in: kept in memory for a while after you sign in.
    const s = st.signin;
    const box = el("div", "apps-signin");
    if (s && s.state === "waiting") {
      const code = el("div", "wl-code small");
      for (const ch of s.user_code) code.append(el("span", ch === "-" ? "dash" : "", ch));
      box.append(el("span", null, "Confirm in the browser to manage apps:"), code);
    } else {
      box.append(el("span", null, "Sign in to connect and manage apps."), button("Sign in", "quiet small", async () => {
        const r = await call("apps_signin");
        if (r.url) await Api.openUrl(r.url).catch(() => {});
        renderApps(grid);
      }));
    }
    tiles.push(box);
  }
  for (const app of st.apps) {
    const t = el("button", "conn-tile " + app.state);
    t.type = "button";
    const logo = el("span", "conn-logo");
    if (APP_LOGOS[app.slug]) { const img = el("img"); img.src = APP_LOGOS[app.slug]; img.alt = ""; logo.append(img); }
    else logo.textContent = app.name.slice(0, 1).toUpperCase();
    const text = el("span", "conn-text");
    text.append(el("strong", null, app.name), el("small", null, app.what));
    const chip = el("span", "conn-chip", {
      connected: app.synced ? `${Number(app.synced).toLocaleString()} synced` : "Connected",
      connecting: "Connecting…", reconnect: "Reconnect", failed: "Try again", off: st.paired ? "Connect" : "Sign in first",
    }[app.state] ?? "Connect");
    t.append(logo, text, chip);
    t.disabled = !st.paired || app.state === "connected" || app.state === "connecting";
    t.title = app.reason || "";
    t.onclick = async () => {
      if (!st.signed_in) return toast("Sign in first", "Connecting an app takes your Enkeon sign-in.", "");
      t.classList.add("connecting"); chip.textContent = "Opening…";
      try {
        const r = await call("app_connect", { slug: app.slug });
        if (r.authorize_url) await Api.openUrl(r.authorize_url).catch(() => {});
        else if (r.state !== "connected") toast(`Couldn't connect ${app.name}`, r.reason || "Enkeon couldn't start it.", "error");
      } catch (e) {
        if (String(e).includes("signin")) toast("Sign in again", "Your sign-in for managing apps has ended.", "");
        else toast(`Couldn't connect ${app.name}`, String(e), "error");
      }
      renderApps(grid);
    };
    tiles.push(t);
  }
  grid.replaceChildren(...tiles);
  // Poll faster while something is connecting or a sign-in is waiting.
  const busy = st.apps.some((a) => a.state === "connecting") || st.signin?.state === "waiting";
  appsTimer = setTimeout(() => renderApps(grid), busy ? 2500 : 15000);
}

/** Pairing or a connect finished somewhere: anything showing apps refreshes. */
function onEnkeonChanged() {
  document.querySelectorAll(".apps-grid").forEach((g) => renderApps(g));
  refreshConnect();
}
