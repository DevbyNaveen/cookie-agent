# Third-party notices

Cookie is MIT licensed. A few parts of it build on other open-source work; their licenses
ask that these notices travel with the code.

## Seatbelt base policy — `src/seatbelt_base_policy.sbpl`

The macOS Seatbelt base policy (deny by default) is taken unmodified from OpenAI Codex,
`codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`, commit `0c329ad`
(https://github.com/openai/codex). Copyright 2025 OpenAI. Licensed under the Apache
License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0). The file carries a
header saying where it came from.

## Skill catalog, learning reviews and agent tools

The skills in `desktop/skills-catalog/` (tool names changed to Cookie's), the review
prompts in `desktop/team/src/learning.rs`, and parts of the design of the checker,
tool search, code tools, voice and workbench in `desktop/team/src/` are adapted from
Hermes Agent (https://github.com/NousResearch/hermes-agent).

Copyright (c) 2025 Nous Research. MIT License:

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

The `humanizer` skill is by Siqi Chen (https://github.com/blader/humanizer), MIT License,
under the notice above.

## Skill safety scan — `desktop/team/src/learning.rs`

The patterns that flag unsafe skill text are adapted from OpenClaw's skill workshop
scanner (https://github.com/openclaw/openclaw).

Copyright (c) 2026 OpenClaw Foundation. MIT License, under the same terms as above.
