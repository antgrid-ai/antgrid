---
title: "A rendering check for engineering notes"
description: "Synthetic content for testing readable code, evidence tables and citations."
publishedAt: 2026-09-12
updatedAt: 2026-09-14
topic: engineering
author: "Test Author"
draft: false
featured: true
claimsVerifiedAt: "abcdef1"
coverImage: /og/control-plane.png
coverImageAlt: "Antgrid control plane social card used as a test image"
action:
  label: "Read the security model"
  href: /security
  category: security
---

This synthetic article exercises the blog layout. It makes no product claims.

## Reading the evidence

An engineering note can link to [the source repository](https://github.com/antgrid-ai/antgrid), explain an observation and cite a reference.[^evidence]

Use `verification_result` for inline code. **Emphasis** and *qualifications* must remain readable.

### A code example

```typescript
const result = { status: "checked", evidence: "a deliberately long line that should scroll inside the code block without widening the surrounding article, even on a narrow phone display with enlarged text" };
console.log(result);
```

### Evidence table

| Scenario | Expected result | Observed result | Follow-up | Reference |
| --- | --- | --- | --- | --- |
| An intentionally verbose scenario | A readable result | A matching observation | Review the evidence | Synthetic fixture |
| A second scenario | Independent scrolling | No page overflow | Keep the context visible | Another fixture |

> A useful investigation includes the limits of its evidence.

- Record the observation.
- Explain the method.
  - Include its limitations.

1. Run the check.
2. Read the output.

<figure>
  <img src="/og/control-plane.png" width="1200" height="630" alt="Antgrid control plane card illustrating a figure in an article" loading="lazy" />
  <figcaption>A caption attached to a synthetic test figure.</figcaption>
</figure>

## Reading the evidence

Repeated headings need distinct, working anchors.

[^evidence]: This citation is synthetic and exists only to test footnotes.
