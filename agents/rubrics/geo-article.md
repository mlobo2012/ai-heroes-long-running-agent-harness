---
name: geo-article
description: Strict evaluator rubric for GEO/SEO article deliverables.
---

# GEO Article Rubric

Use this rubric for GEO/SEO article goals where the output must be useful to
human readers and extractable by AI search systems.

## Verdict Rule

Return `PASS` only when every dimension below is `PASS`. Return `NEEDS_WORK`
when any dimension is `NEEDS_WORK`, and name the failing dimension or
dimensions.

## Dimensions

| Dimension | Weight | PASS | NEEDS_WORK |
|---|---:|---|---|
| Trust signals | 20% | The article includes clear E-E-A-T markers: named author or owner, relevant expertise cues, credible citations or source references, and transparent claims. | The article makes unsupported claims, hides authorship, lacks citations for non-obvious facts, or reads like generic filler. |
| Information gain vs SERP top 3 | 20% | The article adds original analysis, examples, frameworks, data, or buyer-useful specificity beyond the likely top three search results. | The article mostly restates commodity SERP advice, lacks a distinct point of view, or fails to answer the query better than existing results. |
| Structured data and schema | 15% | The deliverable specifies appropriate schema opportunities such as `Article`, `FAQPage`, `HowTo`, `BreadcrumbList`, or entity markup, with fields that match the page content. | Schema is absent, mismatched, spammy, or too vague for implementation. |
| Word count and chunk extractability | 20% | The article is long enough to cover the topic, organized into extractable sections, uses descriptive headings, and includes concise answer-style paragraphs AI systems can lift without losing context. | The article is too thin, poorly chunked, heading-light, or written in long blocks that are hard for AI search systems to quote or summarize. |
| Author, date, and freshness signals | 15% | The article includes publish or update date expectations, freshness cues, and review/update guidance where the topic changes over time. | The article omits date/freshness handling or treats volatile claims as evergreen. |
| Conversion and reader utility | 10% | The article gives the target reader a practical next step, decision aid, checklist, or diagnostic path without turning into a hard-sell page. | The article has no useful next action, over-indexes on promotion, or leaves the reader without a decision path. |

## Grading Notes

- A credible GEO article should win on usefulness first; optimization details
  cannot rescue thin or undifferentiated content.
- Cite failing dimensions by their exact names from the table.
- Treat missing source evidence as a Trust signals failure even if the prose is
  polished.
