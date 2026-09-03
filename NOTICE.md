# Third-Party Notices

This repository contains files derived from third-party models. They are listed
here because redistributing them carries obligations that travel with the files.

---

## Gemma (Google)

Two on-device models come from Google's Gemma family:

- **Gemma 2B IT** — the generator, downloaded at runtime and not stored here
- **EmbeddingGemma-300m** — the query encoder, downloaded at runtime and not
  stored here

Several files **in this repository** are derived from EmbeddingGemma and its
tokenizer, and are Model Derivatives under Google's terms:

| file | what it is |
|---|---|
| `assets/index/tokenizer.bin` | Gemma's BPE vocabulary and merge table, repacked for the app to read without a JSON parser |
| `assets/index/passages.f32` | EmbeddingGemma output vectors for the survival guides |
| `test/fixtures/query_vectors.f32` | EmbeddingGemma output vectors for the evaluation queries |
| `test/fixtures/tokenizer_cases.json` | expected token ids from Gemma's tokenizer |
| `test/fixtures/retrieval_parity.json` | cosine scores computed from those vectors |

Their use, reproduction and distribution are subject to the **Gemma Terms of
Use** and the **Gemma Prohibited Use Policy**:

- https://ai.google.dev/gemma/terms
- https://ai.google.dev/gemma/prohibited_use_policy

Anyone redistributing this repository, or a build of it, must pass those terms
and that policy on to their recipients. The restrictions in the Prohibited Use
Policy apply to these derived files as they do to the models themselves.

Gemma is a trademark of Google LLC. This project is not affiliated with,
endorsed by, or sponsored by Google.

### Rebuilding rather than trusting these files

Every derived file above is reproducible from the upstream models:

```bash
python3 -m survive_rag pack --tokenizer <path to embeddinggemma tokenizer.json>
python3 -m evals parity
```

Both models are gated on Hugging Face and require accepting the Gemma terms on
their model pages before download.

---

## ONNX export

`onnx-community/embeddinggemma-300m-ONNX` supplies the quantised graph the app
downloads. It is a conversion of Google's weights and carries the same Gemma
terms.

---

## Survival guide content

`docs/survival_guides/` is written for this project and draws on public
guidance from Indian and international bodies — NDMA advisories, WHO and Indian
Red Cross first-aid guidance, and national snakebite protocols. It is written
material, not a reproduction of any single source.

**It is not medical advice.** The app states this on first launch, and the
guides are no substitute for emergency services (112 in India) or a clinician.

---

## Project licence

This project does not yet carry a licence file. Until one is added, no licence
is granted for the project's own code and content, and the third-party terms
above continue to apply to the files they name regardless.
