# Public memory QA evaluation status

Status: **not run — the user selected local retrieval evaluation only**.

No LoCoMo or LongMemEval conversation was sent to a model for extraction,
answering, or judging. No end-to-end QA score, automatic-save score, or comparison
with vendor answer-accuracy claims is established by the local retrieval results.

Before that scope selection, one isolated authentication probe completed with
`claude-haiku-4-5-20251001`. It asked for a fixed acknowledgement and used no tools,
memory servers, dataset content, or native memory. Claude reported 3,742 input
tokens, 10 output tokens, no cache tokens, and $0.003792 at API list-price
equivalent. The actual account charge is unknown. The probe took 3.9 seconds.

Only authentication files were copied into a fresh temporary native home, under
the user's existing authorization. Those three copies were removed after the
scope selection. The user's original authentication, configuration, and memory
were not modified. No QA inference process remains running.

Resuming QA requires a model-backed evaluation scope and budget, fixed extraction,
answerer and judge configuration, question-independent ingestion, and separate
reporting of retrieval evidence coverage, answer correctness, tokens and cost.
