# Not doing

- No default model or provider. You name one.
- No hidden prompts. The harness adds nothing to your instructions.
- No chains, graphs, crews, prompt templates, retrievers or vector stores.
- No self-improvement: the harness never rewrites its own prompts or tools.
- No blackboards or voting swarms. Multi-agent is sub-agents and handoffs only.
- No auto-approval for anything that sends, deletes or pays.
- No secrets in context: providers read keys from the environment.
- No built-in price table: you supply prices, so a dollar cap is never computed from stale numbers.
- No model proxy: the harness calls providers directly with your keys (Enkeon's gateway is context, not a model).
- No earned trust for anything that sends, deletes or pays.
- No fake models in the shipped binary: a test double lives in the library's tests only.
