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

const APP_LOGOS = {"gmail": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMTkzIj48cGF0aCBmaWxsPSIjNDI4NUY0IiBkPSJNNTguMTgyIDE5Mi4wNVY5My4xNEwyNy41MDcgNjUuMDc3TDAgNDkuNTA0djEyNS4wOTFjMCA5LjY1OCA3LjgyNSAxNy40NTUgMTcuNDU1IDE3LjQ1NXoiLz48cGF0aCBmaWxsPSIjMzRBODUzIiBkPSJNMTk3LjgxOCAxOTIuMDVoNDAuNzI3YzkuNjU5IDAgMTcuNDU1LTcuODI2IDE3LjQ1NS0xNy40NTVWNDkuNTA1bC0zMS4xNTYgMTcuODM3bC0yNy4wMjYgMjUuNzk4eiIvPjxwYXRoIGZpbGw9IiNFQTQzMzUiIGQ9Im01OC4xODIgOTMuMTRsLTQuMTc0LTM4LjY0N2w0LjE3NC0zNi45ODlMMTI4IDY5Ljg2OGw2OS44MTgtNTIuMzY0bDQuNjY5IDM0Ljk5MmwtNC42NjkgNDAuNjQ0TDEyOCAxNDUuNTA0eiIvPjxwYXRoIGZpbGw9IiNGQkJDMDQiIGQ9Ik0xOTcuODE4IDE3LjUwNFY5My4xNEwyNTYgNDkuNTA0VjI2LjIzMWMwLTIxLjU4NS0yNC42NC0zMy44OS00MS44OS0yMC45NDV6Ii8+PHBhdGggZmlsbD0iI0M1MjIxRiIgZD0ibTAgNDkuNTA0bDI2Ljc1OSAyMC4wN0w1OC4xODIgOTMuMTRWMTcuNTA0TDQxLjg5IDUuMjg2QzI0LjYxLTcuNjYgMCA0LjY0NiAwIDI2LjIzeiIvPjwvc3ZnPg==", "google_calendar": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48cGF0aCBmaWxsPSIjRkZGIiBkPSJNMTk1LjM2OCA2MC42MzJINjAuNjMydjEzNC43MzZoMTM0LjczNnoiLz48cGF0aCBmaWxsPSIjRUE0MzM1IiBkPSJNMTk1LjM2OCAyNTZMMjU2IDE5NS4zNjhsLTMwLjMxNi01LjE3MmwtMzAuMzE2IDUuMTcybC01LjUzMyAyNy43M3oiLz48cGF0aCBmaWxsPSIjMTg4MDM4IiBkPSJNMCAxOTUuMzY4djQwLjQyMUMwIDI0Ni45NTYgOS4wNDQgMjU2IDIwLjIxIDI1Nmg0MC40MjJsNi4yMjUtMzAuMzE2bC02LjIyNS0zMC4zMTZsLTMzLjAzMy01LjE3MnoiLz48cGF0aCBmaWxsPSIjMTk2N0QyIiBkPSJNMjU2IDYwLjYzMlYyMC4yMUMyNTYgOS4wNDQgMjQ2Ljk1NiAwIDIzNS43OSAwaC00MC40MjJxLTUuNTMyIDIyLjU1NC01LjUzMyAzMy4xOTZxMCAxMC42NDEgNS41MzMgMjcuNDM2cTIwLjExNSA1Ljc2IDMwLjMxNiA1Ljc2VDI1NiA2MC42MzEiLz48cGF0aCBmaWxsPSIjRkJCQzA0IiBkPSJNMjU2IDYwLjYzMmgtNjAuNjMydjEzNC43MzZIMjU2eiIvPjxwYXRoIGZpbGw9IiMzNEE4NTMiIGQ9Ik0xOTUuMzY4IDE5NS4zNjhINjAuNjMyVjI1NmgxMzQuNzM2eiIvPjxwYXRoIGZpbGw9IiM0Mjg1RjQiIGQ9Ik0xOTUuMzY4IDBIMjAuMjExQzkuMDQ0IDAgMCA5LjA0NCAwIDIwLjIxdjE3NS4xNThoNjAuNjMyVjYwLjYzMmgxMzQuNzM2eiIvPjxwYXRoIGZpbGw9IiM0Mjg1RjQiIGQ9Ik04OC4yNyAxNjUuMTU0Yy01LjAzNi0zLjQwMi04LjUyMy04LjM3LTEwLjQyNi0xNC45NGwxMS42ODktNC44MTZxMS41OSA2LjA2MyA1LjU1OCA5LjM5OGMyLjYyNyAyLjIyMyA1LjgyNyAzLjMxOCA5LjU2NiAzLjMxOHE1LjczNCAwIDkuODUyLTMuNDg3YzIuNzQ2LTIuMzI0IDQuMTI3LTUuMjg4IDQuMTI3LTguODc1cTAtNS41MDgtNC4zNDUtOC45OTRjLTIuODk3LTIuMzI0LTYuNTM1LTMuNDg2LTEwLjg4LTMuNDg2aC02Ljc1NHYtMTEuNTdoNi4wNjNxNS42MDggMCA5LjQ0OC0zLjAzM2MyLjU2LTIuMDIgMy44NC00Ljc4MyAzLjg0LTguMzAzYzAtMy4xMzItMS4xNDUtNS42MjUtMy40MzUtNy40OTRjLTIuMjktMS44Ny01LjE4OC0yLjgxMy04LjcwOC0yLjgxM2MtMy40MzYgMC02LjE2NC45MS04LjE4NSAyLjc0NWExNi4xIDE2LjEgMCAwIDAtNC40MTMgNi43NTRsLTExLjU3LTQuODE3YzEuNTMyLTQuMzQ1IDQuMzQ1LTguMTg1IDguNDcxLTExLjUwM3M5LjM5OC00Ljk4NSAxNS43OTgtNC45ODVjNC43MzMgMCA4Ljk5NC45MSAxMi43NjcgMi43NDVjMy43NzIgMS44MzYgNi43MzYgNC4zNzkgOC44NzUgNy42MTNjMi4xNCAzLjI1IDMuMiA2Ljg4OCAzLjIgMTAuOTNjMCA0LjEyNi0uOTkzIDcuNjEzLTIuOTggMTAuNDc2cy00LjQzIDUuMDUyLTcuMzI3IDYuNTg1di42OWEyMi4yNSAyMi4yNSAwIDAgMSA5LjM5OCA3LjMyN2MyLjQ0MiAzLjI4NCAzLjY3MiA3LjIwOCAzLjY3MiAxMS43OWMwIDQuNTgtMS4xNjMgOC42NzMtMy40ODcgMTIuMjZjLTIuMzI0IDMuNTg4LTUuNTQgNi40MTctOS42MTcgOC40NzJjLTQuMDkyIDIuMDU1LTguNjkgMy4xLTEzLjc5MyAzLjFjLTUuOTEyLjAxNi0xMS4zNjktMS42ODUtMTYuNDA1LTUuMDg3bTcxLjc5Ny01OC4wMDVsLTEyLjgzMyA5LjI4bC02LjQxNy05LjczNGwyMy4wMjMtMTYuNjA3aDguODI1djc4LjMzM2gtMTIuNTk4eiIvPjwvc3ZnPg==", "slack": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48cGF0aCBmaWxsPSIjRTAxRTVBIiBkPSJNNTMuODQxIDE2MS4zMmMwIDE0LjgzMi0xMS45ODcgMjYuODItMjYuODE5IDI2LjgyUy4yMDMgMTc2LjE1Mi4yMDMgMTYxLjMyYzAtMTQuODMxIDExLjk4Ny0yNi44MTggMjYuODItMjYuODE4SDUzLjg0em0xMy40MSAwYzAtMTQuODMxIDExLjk4Ny0yNi44MTggMjYuODE5LTI2LjgxOHMyNi44MTkgMTEuOTg3IDI2LjgxOSAyNi44MTl2NjcuMDQ3YzAgMTQuODMyLTExLjk4NyAyNi44Mi0yNi44MiAyNi44MmMtMTQuODMgMC0yNi44MTgtMTEuOTg4LTI2LjgxOC0yNi44MnoiLz48cGF0aCBmaWxsPSIjMzZDNUYwIiBkPSJNOTQuMDcgNTMuNjM4Yy0xNC44MzIgMC0yNi44Mi0xMS45ODctMjYuODItMjYuODE5Uzc5LjIzOSAwIDk0LjA3IDBzMjYuODE5IDExLjk4NyAyNi44MTkgMjYuODE5djI2Ljgyem0wIDEzLjYxM2MxNC44MzIgMCAyNi44MTkgMTEuOTg3IDI2LjgxOSAyNi44MTlzLTExLjk4NyAyNi44MTktMjYuODIgMjYuODE5SDI2LjgyQzExLjk4NyAxMjAuODg5IDAgMTA4LjkwMiAwIDk0LjA2OWMwLTE0LjgzIDExLjk4Ny0yNi44MTggMjYuODE5LTI2LjgxOHoiLz48cGF0aCBmaWxsPSIjMkVCNjdEIiBkPSJNMjAxLjU1IDk0LjA3YzAtMTQuODMyIDExLjk4Ny0yNi44MiAyNi44MTgtMjYuODJzMjYuODIgMTEuOTg4IDI2LjgyIDI2Ljgycy0xMS45ODggMjYuODE5LTI2LjgyIDI2LjgxOUgyMDEuNTV6bS0xMy40MSAwYzAgMTQuODMyLTExLjk4OCAyNi44MTktMjYuODIgMjYuODE5Yy0xNC44MzEgMC0yNi44MTgtMTEuOTg3LTI2LjgxOC0yNi44MlYyNi44MkMxMzQuNTAyIDExLjk4NyAxNDYuNDg5IDAgMTYxLjMyIDBzMjYuODE5IDExLjk4NyAyNi44MTkgMjYuODE5eiIvPjxwYXRoIGZpbGw9IiNFQ0IyMkUiIGQ9Ik0xNjEuMzIgMjAxLjU1YzE0LjgzMiAwIDI2LjgyIDExLjk4NyAyNi44MiAyNi44MThzLTExLjk4OCAyNi44Mi0yNi44MiAyNi44MmMtMTQuODMxIDAtMjYuODE4LTExLjk4OC0yNi44MTgtMjYuODJWMjAxLjU1em0wLTEzLjQxYy0xNC44MzEgMC0yNi44MTgtMTEuOTg4LTI2LjgxOC0yNi44MmMwLTE0LjgzMSAxMS45ODctMjYuODE4IDI2LjgxOS0yNi44MThoNjcuMjVjMTQuODMyIDAgMjYuODIgMTEuOTg3IDI2LjgyIDI2LjgxOXMtMTEuOTg4IDI2LjgxOS0yNi44MiAyNi44MTl6Ii8+PC9zdmc+", "google_drive": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjI5Ij48cGF0aCBmaWxsPSIjMDA2NkRBIiBkPSJtMTkuMzU0IDE5Ni4wMzRsMTEuMjkgMTkuNWMyLjM0NiA0LjEwNiA1LjcxOCA3LjMzMiA5LjY3NyA5LjY3OHExNy4wMDktMjEuNTkxIDIzLjY4LTMzLjEzN3E2Ljc3LTExLjcxNyAxNi42NDEtMzYuNjU1cS0yNi42MDQtMy41MDItNDAuMzItMy41MDJxLTEzLjE2NSAwLTQwLjMyMiAzLjUwMmMwIDQuNTQ1IDEuMTczIDkuMDkgMy41MTkgMTMuMTk2eiIvPjxwYXRoIGZpbGw9IiNFQTQzMzUiIGQ9Ik0yMTUuNjgxIDIyNS4yMTJjMy45Ni0yLjM0NiA3LjMzMi01LjU3MiA5LjY3Ny05LjY3N2w0LjY5Mi04LjA2NGwyMi40MzQtMzguODU1YTI2LjU3IDI2LjU3IDAgMCAwIDMuNTE4LTEzLjE5NnEtMjcuMzE1LTMuNTAyLTQwLjI0Ny0zLjUwMnEtMTMuODk5IDAtNDAuMjQ4IDMuNTAycTkuNzU0IDI1LjA3NSAxNi40MjIgMzYuNjU1cTYuNzI0IDExLjY4MyAyMy43NTIgMzMuMTM3Ii8+PHBhdGggZmlsbD0iIzAwODMyRCIgZD0iTTEyOC4wMDEgNzMuMzExcTE5LjY4LTIzLjc2OCAyNy4xMjUtMzYuNjU1cTUuOTk2LTEwLjM3NyAxMy4xOTYtMzMuMTM3QzE2NC4zNjMgMS4xNzMgMTU5LjgxOCAwIDE1NS4xMjYgMGgtNTQuMjVDOTYuMTg0IDAgOTEuNjQgMS4zMiA4Ny42OCAzLjUxOXE5LjE2IDI2LjEwMyAxNS41NDQgMzcuMTU0cTcuMDU2IDEyLjIxMyAyNC43NzcgMzIuNjM4Ii8+PHBhdGggZmlsbD0iIzI2ODRGQyIgZD0iTTE3NS4zNiAxNTUuNDJIODAuNjQybC00MC4zMiA2OS43OTJjMy45NTggMi4zNDYgOC41MDMgMy41MTkgMTMuMTk1IDMuNTE5aDE0OC45NjhjNC42OTIgMCA5LjIzOC0xLjMyIDEzLjE5Ni0zLjUyeiIvPjxwYXRoIGZpbGw9IiMwMEFDNDciIGQ9Ik0xMjguMDAxIDczLjMxMUw4Ny42ODEgMy41MmMtMy45NiAyLjM0Ni03LjMzMiA1LjU3MS05LjY3OCA5LjY3N0wzLjUxOSAxNDIuMjI0QTI2LjU3IDI2LjU3IDAgMCAwIDAgMTU1LjQyaDgwLjY0MnoiLz48cGF0aCBmaWxsPSIjRkZCQTAwIiBkPSJtMjE1LjI0MiA3Ny43MWwtMzcuMjQzLTY0LjUxNGMtMi4zNDUtNC4xMDYtNS43MTgtNy4zMzEtOS42NzctOS42NzdsLTQwLjMyIDY5Ljc5Mmw0Ny4zNTggODIuMTA5aDgwLjQ5NmMwLTQuNTQ2LTEuMTczLTkuMDktMy41MTktMTMuMTk2eiIvPjwvc3ZnPg==", "notion": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjY4Ij48cGF0aCBmaWxsPSIjRkZGIiBkPSJNMTYuMDkyIDExLjUzOEwxNjQuMDkuNjA4YzE4LjE3OS0xLjU2IDIyLjg1LS41MDggMzQuMjggNy44MDFsNDcuMjQzIDMzLjI4MkMyNTMuNDA2IDQ3LjQxNCAyNTYgNDguOTc1IDI1NiA1NS4yMDd2MTgyLjUyN2MwIDExLjQzOS00LjE1NSAxOC4yMDUtMTguNjk2IDE5LjI0TDY1LjQ0IDI2Ny4zNzhjLTEwLjkxMy41MTctMTYuMTEtMS4wNDMtMjEuODI1LTguMzI3TDguODI2IDIxMy44MTRDMi41ODYgMjA1LjQ4NyAwIDE5OS4yNTQgMCAxOTEuOTdWMjkuNzI2YzAtOS4zNTIgNC4xNTUtMTcuMTUzIDE2LjA5Mi0xOC4xODgiLz48cGF0aCBkPSJNMTY0LjA5LjYwOEwxNi4wOTIgMTEuNTM4QzQuMTU1IDEyLjU3MyAwIDIwLjM3NCAwIDI5LjcyNnYxNjIuMjQ1YzAgNy4yODQgMi41ODUgMTMuNTE2IDguODI2IDIxLjg0M2wzNC43ODkgNDUuMjM3YzUuNzE1IDcuMjg0IDEwLjkxMiA4Ljg0NCAyMS44MjUgOC4zMjdsMTcxLjg2NC0xMC40MDRjMTQuNTMyLTEuMDM1IDE4LjY5Ni03LjgwMSAxOC42OTYtMTkuMjRWNTUuMjA3YzAtNS45MTEtMi4zMzYtNy42MTQtOS4yMS0xMi42NmwtMS4xODUtLjg1NkwxOTguMzcgOC40MDlDMTg2Ljk0LjEgMTgyLjI3LS45NTIgMTY0LjA5LjYwOE02OS4zMjcgNTIuMjJjLTE0LjAzMy45NDUtMTcuMjE2IDEuMTU5LTI1LjE4Ni01LjMyM0wyMy44NzYgMzAuNzc4Yy0yLjA2LTIuMDg2LTEuMDI2LTQuNjkgNC4xNjMtNS4yMDdsMTQyLjI3NC0xMC4zOTVjMTEuOTQ3LTEuMDQzIDE4LjE3IDMuMTIgMjIuODQyIDYuNzU4bDI0LjQwMSAxNy42OGMxLjA0My41MjUgMy42MzggMy42MzcuNTE3IDMuNjM3TDcxLjE0NiA1Mi4wOTV6bS0xNi4zNiAxODMuOTU0VjgxLjIyMmMwLTYuNzY3IDIuMDc3LTkuODg3IDguMy0xMC40MTNMMjMwLjAyIDYwLjkzYzUuNzI0LS41MTcgOC4zMSAzLjEyIDguMzEgOS44Nzl2MTUzLjkxN2MwIDYuNzY3LTEuMDQ0IDEyLjQ5LTEwLjM4NyAxMy4wMDhsLTE2MS40ODcgOS4zNjFjLTkuMzQzLjUxNy0xMy40ODktMi41OTQtMTMuNDg5LTEwLjkyMU0yMTIuMzc3IDg5LjUzYzEuMDM0IDQuNjgxIDAgOS4zNjItNC42ODEgOS44OTdsLTcuNzgzIDEuNTQydjExNC40MDRjLTYuNzU4IDMuNjM3LTEyLjk4MSA1LjcxNS0xOC4xOCA1LjcxNWMtOC4zMDggMC0xMC4zODYtMi42MDQtMTYuNjA5LTEwLjM5NmwtNTAuODk4LTgwLjA3OXY3Ny40NzZsMTYuMSAzLjY0NnMwIDkuMzYyLTEyLjk4OSA5LjM2MmwtMzUuODE0IDIuMDc3Yy0xLjA0My0yLjA4NiAwLTcuMjg0IDMuNjMtOC4zMThsOS4zNTEtMi41OTVWMTA5LjgyM2wtMTIuOTgtMS4wNTJjLTEuMDQ0LTQuNjggMS41NS0xMS40MzkgOC44MjYtMTEuOTY1bDM4LjQyNi0yLjU4NWw1Mi45NTggODEuMTEzdi03MS43NmwtMTMuNDk4LTEuNTUyYy0xLjA0My01LjczMyAzLjExMS05Ljg5NiA4LjMtMTAuNDA0eiIvPjwvc3ZnPg==", "github": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjUwIj48cGF0aCBmaWxsPSIjMTYxNjE0IiBkPSJNMTI4LjAwMSAwQzU3LjMxNyAwIDAgNTcuMzA3IDAgMTI4LjAwMWMwIDU2LjU1NCAzNi42NzYgMTA0LjUzNSA4Ny41MzUgMTIxLjQ2YzYuMzk3IDEuMTg1IDguNzQ2LTIuNzc3IDguNzQ2LTYuMTU4YzAtMy4wNTItLjEyLTEzLjEzNS0uMTc0LTIzLjgzYy0zNS42MSA3Ljc0Mi00My4xMjQtMTUuMTAzLTQzLjEyNC0xNS4xMDNjLTUuODIzLTE0Ljc5NS0xNC4yMTMtMTguNzMtMTQuMjEzLTE4LjczYy0xMS42MTMtNy45NDQuODc2LTcuNzguODc2LTcuNzhjMTIuODUzLjkwMiAxOS42MjEgMTMuMTkgMTkuNjIxIDEzLjE5YzExLjQxNyAxOS41NjggMjkuOTQ1IDEzLjkxMSAzNy4yNDkgMTAuNjRjMS4xNDktOC4yNzIgNC40NjYtMTMuOTIgOC4xMjctMTcuMTE2Yy0yOC40MzEtMy4yMzYtNTguMzE4LTE0LjIxMi01OC4zMTgtNjMuMjU4YzAtMTMuOTc1IDUtMjUuMzk0IDEzLjE4OC0zNC4zNThjLTEuMzI5LTMuMjI0LTUuNzEtMTYuMjQyIDEuMjQtMzMuODc0YzAgMCAxMC43NDktMy40NCAzNS4yMSAxMy4xMjFjMTAuMjEtMi44MzYgMjEuMTYtNC4yNTggMzIuMDM4LTQuMzA3YzEwLjg3OC4wNDkgMjEuODM3IDEuNDcgMzIuMDY2IDQuMzA3YzI0LjQzMS0xNi41NiAzNS4xNjUtMTMuMTIgMzUuMTY1LTEzLjEyYzYuOTY3IDE3LjYzIDIuNTg0IDMwLjY1IDEuMjU1IDMzLjg3M2M4LjIwNyA4Ljk2NCAxMy4xNzMgMjAuMzgzIDEzLjE3MyAzNC4zNThjMCA0OS4xNjMtMjkuOTQ0IDU5Ljk4OC01OC40NDcgNjMuMTU3YzQuNTkxIDMuOTcyIDguNjgyIDExLjc2MiA4LjY4MiAyMy43MDRjMCAxNy4xMjYtLjE0OCAzMC45MS0uMTQ4IDM1LjEyNmMwIDMuNDA3IDIuMzA0IDcuMzk4IDguNzkyIDYuMTRDMjE5LjM3IDIzMi41IDI1NiAxODQuNTM3IDI1NiAxMjguMDAyQzI1NiA1Ny4zMDcgMTk4LjY5MSAwIDEyOC4wMDEgMG0tODAuMDYgMTgyLjM0Yy0uMjgyLjYzNi0xLjI4My44MjctMi4xOTQuMzljLS45MjktLjQxNy0xLjQ1LTEuMjg0LTEuMTUtMS45MjJjLjI3Ni0uNjU1IDEuMjc5LS44MzggMi4yMDUtLjM5OWMuOTMuNDE4IDEuNDYgMS4yOTMgMS4xMzkgMS45MzFtNi4yOTYgNS42MThjLS42MS41NjYtMS44MDQuMzAzLTIuNjE0LS41OTFjLS44MzctLjg5Mi0uOTk0LTIuMDg2LS4zNzUtMi42NmMuNjMtLjU2NiAxLjc4Ny0uMzAxIDIuNjI2LjU5MWMuODM4LjkwMyAxIDIuMDg4LjM2MyAyLjY2bTQuMzIgNy4xODhjLS43ODUuNTQ1LTIuMDY3LjAzNC0yLjg2LTEuMTA0Yy0uNzg0LTEuMTM4LS43ODQtMi41MDMuMDE3LTMuMDVjLjc5NS0uNTQ3IDIuMDU4LS4wNTUgMi44NjEgMS4wNzVjLjc4MiAxLjE1Ny43ODIgMi41MjItLjAxOSAzLjA4bTcuMzA0IDguMzI1Yy0uNzAxLjc3NC0yLjE5Ni41NjYtMy4yOS0uNDljLTEuMTE5LTEuMDMyLTEuNDMtMi40OTYtLjcyNi0zLjI3Yy43MS0uNzc2IDIuMjEzLS41NTggMy4zMTUuNDljMS4xMSAxLjAzIDEuNDUgMi41MDUuNzAxIDMuMjdtOS40NDIgMi44MWMtLjMxIDEuMDAzLTEuNzUgMS40NTktMy4xOTkgMS4wMzNjLTEuNDQ4LS40MzktMi4zOTUtMS42MTMtMi4xMDMtMi42MjZjLjMwMS0xLjAxIDEuNzQ3LTEuNDg0IDMuMjA3LTEuMDI4YzEuNDQ2LjQzNiAyLjM5NiAxLjYwMiAyLjA5NSAyLjYyMm0xMC43NDQgMS4xOTNjLjAzNiAxLjA1NS0xLjE5MyAxLjkzLTIuNzE1IDEuOTVjLTEuNTMuMDM0LTIuNzY5LS44Mi0yLjc4Ni0xLjg2YzAtMS4wNjUgMS4yMDItMS45MzIgMi43MzMtMS45NThjMS41MjItLjAzIDIuNzY4LjgxOCAyLjc2OCAxLjg2OG0xMC41NTUtLjQwNWMuMTgyIDEuMDMtLjg3NSAyLjA4OC0yLjM4NyAyLjM3Yy0xLjQ4NS4yNzEtMi44NjEtLjM2NS0zLjA1LTEuMzg2Yy0uMTg0LTEuMDU2Ljg5My0yLjExNCAyLjM3Ni0yLjM4N2MxLjUxNC0uMjYzIDIuODY4LjM1NiAzLjA2MSAxLjQwMyIvPjwvc3ZnPg==", "outlook": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iIzAwNzhENCIgZD0iTTcuODggMTIuMDRxMCAuNDUtLjExLjg3cS0uMS40MS0uMzMuNzRxLS4yMi4zMy0uNTguNTJxLS4zNy4yLS44Ny4ydC0uODUtLjJxLS4zNS0uMjEtLjU3LS41NXEtLjIyLS4zMy0uMzMtLjc1cS0uMS0uNDItLjEtLjg2dC4xLS44N3QuMzQtLjc2cS4yMi0uMzQuNTktLjU0cS4zNi0uMi44Ny0uMnQuODYuMnEuMzUuMjEuNTcuNTV0LjMxLjc3cS4xLjQzLjEuODhNMjQgMTJ2OS4zOHEwIC40Ni0uMzMuOHEtLjMzLjMyLS44LjMySDcuMTNxLS40NiAwLS44LS4zM3EtLjMyLS4zMy0uMzItLjhWMThIMXEtLjQxIDAtLjctLjNxLS4zLS4yOS0uMy0uN1Y3cTAtLjQxLjMtLjdRLjU4IDYgMSA2aDYuNVYyLjU1cTAtLjQ0LjMtLjc1cS4zLS4zLjc1LS4zaDEyLjlxLjQ0IDAgLjc1LjNxLjMuMy4zLjc1djguM2wxLjI0LjcyaC4wMXEuMS4wNy4xOC4xOHEuMDcuMTIuMDcuMjVtLTYtOC4yNXYzaDN2LTN6bTAgNC41djNoM3YtM3ptMCA0LjV2MS44M2wzLjA1LTEuODN6bS01LjI1LTl2M2gzLjc1di0zem0wIDQuNXYzaDMuNzV2LTN6bTAgNC41djIuMDNsMi40MSAxLjVsMS4zNC0uOHYtMi43M3pNOSAzLjc1VjZoMmwuMTMuMDFsLjEyLjA0di0yLjN6TTUuOTggMTUuOThxLjkgMCAxLjYtLjNxLjctLjMyIDEuMTktLjg2cS40OC0uNTUuNzMtMS4yOHEuMjUtLjc0LjI1LTEuNjFxMC0uODMtLjI1LTEuNTVxLS4yNC0uNzEtLjcxLTEuMjR0LTEuMTUtLjgzdC0xLjU1LS4zcS0uOTIgMC0xLjY0LjNxLS43MS4zLTEuMi44NXEtLjUuNTQtLjc1IDEuM3EtLjI1Ljc0LS4yNSAxLjYzcTAgLjg1LjI2IDEuNTZxLjI2LjcyLjc0IDEuMjNxLjQ4LjUyIDEuMTcuODFxLjY5LjMgMS41Ni4zek03LjUgMjFoMTIuMzlMMTIgMTYuMDhWMTdxMCAuNDEtLjMuN3EtLjI5LjMtLjcuM0g3LjV6bTE1LS4xM3YtNy4yNGwtNS45IDMuNTRaIi8+PC9zdmc+", "linear": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48cGF0aCBmaWxsPSIjMjIyMzI2IiBkPSJtOC4xNzQgMTAyLjYxM2wxNDUuMjEzIDE0NS4yMTNjMi4xMiAyLjEyIDEuMDk3IDUuNzItMS44NSA2LjI3YTEyOCAxMjggMCAwIDEtMTUuMDIgMS44OTZhMy43OCAzLjc4IDAgMCAxLTIuOTItMS4xMDlMMS4xMTcgMTIyLjQwM2EzLjc4IDMuNzggMCAwIDEtMS4xMDktMi45MmMuMzQtNS4wOTUuOTc4LTEwLjEwNyAxLjg5Ni0xNS4wMmMuNTUtMi45NDcgNC4xNS0zLjk3IDYuMjctMS44NW0tNC4wOTIgNTguNzk2Yy0uOTctMy42MTQgMy4zLTUuODk0IDUuOTQ2LTMuMjQ4bDg3LjgxIDg3LjgxMWMyLjY0NyAyLjY0Ni4zNjcgNi45MTUtMy4yNDcgNS45NDZjLTQ0LjAzLTExLjgwNS03OC43MDQtNDYuNDc4LTkwLjUxLTkwLjUwOW0xMi43MjctOTcuMjQ1YzEuMjMzLTIuMTM1IDQuMTQ3LTIuNDYzIDUuODktLjcxOUwxOTIuNTU2IDIzMy4zYzEuNzQ0IDEuNzQ0IDEuNDE3IDQuNjU4LS43MiA1Ljg5MWExMjggMTI4IDAgMCAxLTExLjEgNS43MDVjLTEuNDMuNjUtMy4xMS4zMjItNC4yMi0uNzlMMTEuODkzIDc5LjQ4N2MtMS4xMTEtMS4xMTItMS40MzktMi43OS0uNzktNC4yMjFhMTI4IDEyOCAwIDAgMSA1LjcwNi0xMS4xTTEyNy44NiAwQzE5OC42MyAwIDI1NiA1Ny4zNyAyNTYgMTI4LjE0YzAgMzcuNTctMTYuMTY4IDcxLjM2Mi00MS45MjYgOTQuOGMtMS40ODcgMS4zNTQtMy43NjggMS4yNjQtNS4xOS0uMTU3TDMzLjIxNyA0Ny4xMTZjLTEuNDIxLTEuNDIyLTEuNTEtMy43MDMtLjE1OC01LjE5QzU2LjQ5OCAxNi4xNjggOTAuMjkxIDAgMTI3Ljg2IDAiLz48L3N2Zz4=", "google_sheets": "data:image/svg+xml;base64,PHN2ZyByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+R29vZ2xlIFNoZWV0czwvdGl0bGU+PHBhdGggZmlsbD0iIzM0QTg1MyIgZD0iTTExLjMxOCAxMi41NDVINy45MXYtMS45MDloMy40MXYxLjkxek0xNC43MjggMHY2aDZsLTYtNnptMS4zNjMgMTAuNjM2aC0zLjQxdjEuOTFoMy40MXYtMS45MXptMCAzLjI3M2gtMy40MXYxLjkxaDMuNDF2LTEuOTF6TTIwLjcyNyA2LjV2MTUuODY0YzAgLjkwNC0uNzMyIDEuNjM2LTEuNjM2IDEuNjM2SDQuOTA5YTEuNjM2IDEuNjM2IDAgMCAxLTEuNjM2LTEuNjM2VjEuNjM2QzMuMjczLjczMiA0LjAwNSAwIDQuOTA5IDBoOS4zMTh2Ni41aDYuNXptLTMuMjczIDIuNzczSDYuNTQ1djcuOTA5aDEwLjkxdi03Ljkxem0tNi4xMzYgNC42MzZINy45MXYxLjkxaDMuNDF2LTEuOTF6Ii8+PC9zdmc+", "hubspot": "data:image/svg+xml;base64,PHN2ZyBmaWxsPSIjRkY3QTU5IiByb2xlPSJpbWciIHZpZXdCb3g9IjAgMCAyNCAyNCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48cGF0aCBkPSJNMTguMTY0IDcuOTNWNS4wODRhMi4xOTggMi4xOTggMCAwMDEuMjY3LTEuOTc4di0uMDY3QTIuMiAyLjIgMCAwMDE3LjIzOC44NDVoLS4wNjdhMi4yIDIuMiAwIDAwLTIuMTkzIDIuMTkzdi4wNjdhMi4xOTYgMi4xOTYgMCAwMDEuMjUyIDEuOTczbC4wMTMuMDA2djIuODUyYTYuMjIgNi4yMiAwIDAwLTIuOTY5IDEuMzFsLjAxMi0uMDEtNy44MjgtNi4wOTVBMi40OTcgMi40OTcgMCAxMDQuMyA0LjY1NmwtLjAxMi4wMDYgNy42OTcgNS45OTFhNi4xNzYgNi4xNzYgMCAwMC0xLjAzOCAzLjQ0NmMwIDEuMzQzLjQyNSAyLjU4OCAxLjE0NyAzLjYwN2wtLjAxMy0uMDItMi4zNDIgMi4zNDNhMS45NjggMS45NjggMCAwMC0uNTgtLjA5NWgtLjAwMmEyLjAzMyAyLjAzMyAwIDEwMi4wMzMgMi4wMzMgMS45NzggMS45NzggMCAwMC0uMS0uNTk1bC4wMDUuMDE0IDIuMzE3LTIuMzE3YTYuMjQ3IDYuMjQ3IDAgMTA0Ljc4Mi0xMS4xMzRsLS4wMzYtLjAwNXptLS45NjQgOS4zNzhhMy4yMDYgMy4yMDYgMCAxMTMuMjE1LTMuMjA3di4wMDJhMy4yMDYgMy4yMDYgMCAwMS0zLjIwNyAzLjIwN3oiLz48L3N2Zz4=", "jira": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImxvZ29zSmlyYTAiIHgxPSI5OC4wMzElIiB4Mj0iNTguODg4JSIgeTE9Ii4xNjElIiB5Mj0iNDAuNzY2JSI+PHN0b3Agb2Zmc2V0PSIxOCUiIHN0b3AtY29sb3I9IiMwMDUyQ0MiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMyNjg0RkYiLz48L2xpbmVhckdyYWRpZW50PjxsaW5lYXJHcmFkaWVudCBpZD0ibG9nb3NKaXJhMSIgeDE9IjEwMC42NjUlIiB4Mj0iNTUuNDAyJSIgeTE9Ii40NTUlIiB5Mj0iNDQuNzI3JSI+PHN0b3Agb2Zmc2V0PSIxOCUiIHN0b3AtY29sb3I9IiMwMDUyQ0MiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMyNjg0RkYiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cGF0aCBmaWxsPSIjMjY4NEZGIiBkPSJNMjQ0LjY1OCAwSDEyMS43MDdhNTUuNSA1NS41IDAgMCAwIDU1LjUwMiA1NS41MDJoMjIuNjQ5Vjc3LjM3Yy4wMiAzMC42MjUgMjQuODQxIDU1LjQ0NyA1NS40NjYgNTUuNDY3VjEwLjY2NkMyNTUuMzI0IDQuNzc3IDI1MC41NSAwIDI0NC42NTggMCIvPjxwYXRoIGZpbGw9InVybCgjbG9nb3NKaXJhMCkiIGQ9Ik0xODMuODIyIDYxLjI2Mkg2MC44NzJjLjAxOSAzMC42MjUgMjQuODQgNTUuNDQ3IDU1LjQ2NiA1NS40NjdoMjIuNjQ5djIxLjkzOGMuMDM5IDMwLjYyNSAyNC44NzcgNTUuNDMgNTUuNTAyIDU1LjQzVjcxLjkzYzAtNS44OTEtNC43NzYtMTAuNjY3LTEwLjY2Ny0xMC42NjciLz48cGF0aCBmaWxsPSJ1cmwoI2xvZ29zSmlyYTEpIiBkPSJNMTIyLjk1MSAxMjIuNDg5SDBjMCAzMC42NTMgMjQuODUgNTUuNTAyIDU1LjUwMiA1NS41MDJoMjIuNzJ2MjEuODY3Yy4wMiAzMC41OTcgMjQuNzk4IDU1LjQwOCA1NS4zOTYgNTUuNDY2VjEzMy4xNTZjMC01Ljg5MS00Ljc3Ni0xMC42NjctMTAuNjY3LTEwLjY2NyIvPjwvc3ZnPg==", "zoom": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNTYgMjU2Ij48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImxvZ29zWm9vbUljb24wIiB4MT0iMjMuNjY2JSIgeDI9Ijc2LjMzNCUiIHkxPSI5NS42MTIlIiB5Mj0iNC4zODglIj48c3RvcCBvZmZzZXQ9IjAlIiBzdG9wLWNvbG9yPSIjMDg0NUJGIi8+PHN0b3Agb2Zmc2V0PSIxOS4xMSUiIHN0b3AtY29sb3I9IiMwOTUwREUiLz48c3RvcCBvZmZzZXQ9IjM4LjIzJSIgc3RvcC1jb2xvcj0iIzBCNTlGNiIvPjxzdG9wIG9mZnNldD0iNTAlIiBzdG9wLWNvbG9yPSIjMEI1Q0ZGIi8+PHN0b3Agb2Zmc2V0PSI2Ny4zMiUiIHN0b3AtY29sb3I9IiMwRTVFRkUiLz48c3RvcCBvZmZzZXQ9Ijc3Ljc0JSIgc3RvcC1jb2xvcj0iIzE2NjVGQyIvPjxzdG9wIG9mZnNldD0iODYuMzMlIiBzdG9wLWNvbG9yPSIjMjQ2RkY5Ii8+PHN0b3Agb2Zmc2V0PSI5My44OCUiIHN0b3AtY29sb3I9IiMzODdGRjQiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiM0RjkwRUUiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cGF0aCBmaWxsPSJ1cmwoI2xvZ29zWm9vbUljb24wKSIgZD0iTTI1NiAxMjhjMCAxMy41NjgtMS4wMjQgMjcuMTM2LTMuMzI4IDQwLjE5MmMtNi45MTIgNDMuMjY0LTQxLjIxNiA3Ny41NjgtODQuNDggODQuNDhDMTU1LjEzNiAyNTQuOTc2IDE0MS41NjggMjU2IDEyOCAyNTZzLTI3LjEzNi0xLjAyNC00MC4xOTItMy4zMjhjLTQzLjI2NC02LjkxMi03Ny41NjgtNDEuMjE2LTg0LjQ4LTg0LjQ4QzEuMDI0IDE1NS4xMzYgMCAxNDEuNTY4IDAgMTI4czEuMDI0LTI3LjEzNiAzLjMyOC00MC4xOTJjNi45MTItNDMuMjY0IDQxLjIxNi03Ny41NjggODQuNDgtODQuNDhDMTAwLjg2NCAxLjAyNCAxMTQuNDMyIDAgMTI4IDBzMjcuMTM2IDEuMDI0IDQwLjE5MiAzLjMyOGM0My4yNjQgNi45MTIgNzcuNTY4IDQxLjIxNiA4NC40OCA4NC40OEMyNTQuOTc2IDEwMC44NjQgMjU2IDExNC40MzIgMjU2IDEyOCIvPjxwYXRoIGZpbGw9IiNGRkYiIGQ9Ik0yMDQuMDMyIDIwNy44NzJINzUuMDA4Yy04LjQ0OCAwLTE2LjY0LTQuNjA4LTIwLjQ4LTEyLjAzMmMtNC42MDgtOC43MDQtMi44MTYtMTkuMiA0LjA5Ni0yNi4xMTJsODkuODU2LTg5Ljg1Nkg4My45NjhjLTE3LjY2NCAwLTMyLTE0LjMzNi0zMi0zMmgxMTguNzg0YzguNDQ4IDAgMTYuNjQgNC42MDggMjAuNDggMTIuMDMyYzQuNjA4IDguNzA0IDIuODE2IDE5LjItNC4wOTYgMjYuMTEybC04OS42IDkwLjExMmg3NC40OTZjMTcuNjY0IDAgMzIgMTQuMDggMzIgMzEuNzQ0Ii8+PC9zdmc+"};
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
