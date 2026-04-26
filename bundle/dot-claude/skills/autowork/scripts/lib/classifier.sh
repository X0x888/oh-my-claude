#!/usr/bin/env bash
# lib/classifier.sh — Prompt classification subsystem.
#
# Extracted from common.sh in v1.13.0 to give the intent/domain classifier
# its own file. Behavior is identical to the prior in-place definitions;
# this module is purely a clearer ownership boundary for future
# maintenance, retraining, and dedicated regression tests
# (test-intent-classification.sh, test-classifier-replay.sh).
#
# Provided functions:
#   is_imperative_request          — P0 imperative detection (regex cascade)
#   count_keyword_matches          — grep-and-count helper
#   is_ui_request                  — frontend/UI prompt detector
#   infer_domain                   — P1 scoring domain classification
#   classify_task_intent           — top-level intent dispatcher
#   record_classifier_telemetry    — per-prompt JSONL telemetry writer
#   detect_classifier_misfire      — post-hoc misfire annotator
#   is_execution_intent_value      — small predicate over the intent string
#
# Required dependencies (must be defined BEFORE this lib is sourced):
#   from common.sh: validate_session_id, log_anomaly, log_hook, now_epoch,
#                   truncate_chars, trim_whitespace, normalize_task_prompt,
#                   extract_skill_primary_task, is_continuation_request,
#                   is_checkpoint_request, is_session_management_request,
#                   is_advisory_request, project_profile_has
#   from lib/state-io.sh: session_file
#   environment: SESSION_ID, OMC_CLASSIFIER_TELEMETRY (with default)
#
# All functions are idempotent and side-effect-free except
# record_classifier_telemetry / detect_classifier_misfire which append to
# the per-session classifier_telemetry.jsonl.

# --- P0: Imperative detection (checked before advisory in classify_task_intent) ---

is_imperative_request() {
  local text="$1"
  local nocasematch_was_set=0

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1

  # "Can/Could/Would you [verb]..." — polite imperatives
  if [[ "${text}" =~ ^[[:space:]]*(can|could|would)[[:space:]]+you[[:space:]]+(please[[:space:]]+)?(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|set[[:space:]]+up|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|tag|release|ship|publish|review|start|stop|enable|disable|open|close|evaluate|plan|audit|investigate|research|analyze|analyse|assess|execute|document|extend|raise|design|style|redesign|treat|diagnose|prioritize|preserve|ensure|perform|prepare|verify|validate|generate|apply|revert|simplify|extract|replace|upgrade|scaffold|swap|split|inline|expose|wire|bootstrap|downgrade|patch|determine|identify|examine|inspect|scan|explore|establish|conduct|complete|address|clean|hook) ]]; then
    result=0
  # "Please [adverb?] [verb]..." patterns — single optional -ly adverb between please and verb
  # Release-action verbs (commit|push|tag|release|ship|publish|merge) added
  # in 1.8.1 so single-clause polite asks like "Please push the changes to
  # main." or "Please tag v2.0." route as execution instead of falling
  # through to the default. Mirrors the tail-imperative branch's narrow
  # destructive-verb list.
  elif [[ "${text}" =~ ^[[:space:]]*(please)[[:space:]]+([a-z]+ly[[:space:]]+)?(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|commit|push|merge|tag|release|ship|publish|proceed|go|evaluate|plan|audit|investigate|research|analyze|analyse|assess|execute|document|extend|raise|design|style|redesign|treat|diagnose|prioritize|preserve|ensure|perform|prepare|verify|validate|generate|apply|revert|simplify|extract|replace|upgrade|scaffold|swap|split|inline|expose|wire|bootstrap|downgrade|patch|determine|identify|examine|inspect|scan|explore|establish|conduct|complete|address|clean|hook) ]]; then
    result=0
  # "Go ahead and..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*go[[:space:]]+ahead ]]; then
    result=0
  # "I need/want you to..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*i[[:space:]]+(need|want)[[:space:]]+(you[[:space:]]+to|to)[[:space:]] ]]; then
    result=0
  # Bare imperative: starts with unambiguous action verb, no trailing question mark
  # Excludes: check, test, help, review, plan, research, evaluate, design, style — too ambiguous as bare starts
  # (evaluate/plan/research can be nouns; design/style are adjective-like)
  # Also polite-only: complete, address, clean, hook, determine, identify, examine,
  # inspect, scan, explore, establish, conduct — noun/adjective-ambiguous at prompt start
  elif [[ ! "${text}" =~ \?[[:space:]]*$ ]] && [[ "${text}" =~ ^[[:space:]]*(fix|implement|add|create|build|update|refactor|debug|deploy|write|make|change|modify|remove|delete|move|rename|install|configure|run|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|start|stop|enable|disable|open|close|set[[:space:]]+up|proceed|audit|investigate|analyze|analyse|execute|document|extend|raise|redesign|treat|diagnose|prioritize|preserve|ensure|perform|prepare|verify|validate|generate|apply|revert|simplify|extract|replace|upgrade|scaffold|swap|split|inline|expose|wire|bootstrap|downgrade|patch)[[:space:]] ]]; then
    result=0
  # Tail-position imperative: a prompt that opens with advisory/evaluation
  # framing but closes with an explicit release-action ask. The CLAUDE.md
  # release checklist prescribes this exact pattern ("comprehensively
  # evaluate each point; after all these, commit the changes and tag").
  # Without this branch, the head-anchored patterns above fail, advisory
  # wins, and PreTool blocks the user's own explicitly-requested commit.
  #
  # Narrow by design:
  #   - Requires a sentence boundary (`. `, `, `, `\n`) before the verb so
  #     past-tense mentions ("we pushed yesterday") don't match.
  #   - Requires an object marker after the verb (article/demonstrative/
  #     preposition/tag-shaped literal) so noun uses ("push date", "the
  #     commit message") don't match.
  #   - Allows optional transition words ("then", "now", "finally", "also",
  #     "afterwards") between the boundary and the verb so "Review the
  #     branch. Then push to origin." is caught without having to enumerate
  #     every possible conjunction.
  #   - Only fires on verbs that are genuinely destructive-execution when
  #     used imperatively: commit/push/tag/release/deploy/merge/ship/publish.
  #     Safer verbs (run/make/create) stay head-anchored.
  elif [[ "${text}" =~ (\.|,|\?|$'\n')[[:space:]]+(then|now|finally|lastly|also|afterwards?|next)?[[:space:]]*,?[[:space:]]*(commit|push|tag|release|deploy|merge|ship|publish)[[:space:]]+(the|a|an|all|these|this|that|those|to[[:space:]]|origin[[:space:]]|upstream[[:space:]]+|v[0-9]|it[[:space:]]|them[[:space:]]+|changes?[[:space:]]|and[[:space:]]) ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

# --- end P0 ---
# --- P1: Scoring-based domain classification ---

count_keyword_matches() {
  local pattern="$1"
  local text="$2"
  { grep -oEi "${pattern}" <<<"${text}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

is_ui_request() {
  local text="$1"
  [[ -z "${text}" ]] && return 1

  # Split UI detection from domain scoring. The router needs to spot common
  # frontend asks ("create a login page", "style an empty state", "polish
  # my dashboard") without turning design-analysis or writing prompts into
  # coding work.
  #
  # Polish-class verbs (polish/refine/improve/enhance/elevate/perfect/
  # beautify/tighten/sharpen) are intentionally **noun-gated** by the same
  # UI-noun list as structural verbs. This means "polish my essay",
  # "improve my draft", "refine my paragraph" do NOT match — those nouns
  # aren't in the UI noun list. Only "polish my landing page", "refine my
  # dashboard", etc. trip detection. See classifier writing-keyword list
  # at line ~227 for the writing-domain side; the noun gate is the
  # disambiguator.
  local structural_ui_actions
  local qualified_form_actions
  local visual_ui_actions
  local motion_ui_actions
  local polish_ui_actions
  local explicit_ui_terms

  structural_ui_actions='\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|dashboards?|screens?|modals?|dialogs?|drawers?|heroes?|nav(igation|bar)?|sidebars?|headers?|footers?|menus?|tabs?|panels?|layouts?|components?|empty.?states?|tables?|charts?|filters?|accordions?|wizards?|steppers?|banners?)\b'
  qualified_form_actions='\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(login|signup|sign[- ]?up|sign[- ]?in|checkout|contact|search|settings|profile|feedback|payment|registration|onboarding|responsive)\s+forms?\b'
  visual_ui_actions='\b(design(ing)?|style|styl(e|ing)|redesign(ing)?|restyle|theme)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|forms?|buttons?|cards?|modals?|dialogs?|drawers?|dropdowns?|nav(igation|bar)?|sidebars?|headers?|footers?|heroes?|layouts?|components?|interfaces?|screens?|dashboards?|sections?|menus?|tabs?|panels?|empty.?states?|tables?|charts?|filters?|banners?|tooltips?|toasts?)\b'
  motion_ui_actions='\b(add(ing)?|create|creat(e|ing)|build(ing)?|make|implement(ing)?|update(ing)?)\s+(a\s+|an\s+|the\s+|some\s+|subtle\s+|micro\s+)?animations?\s+(to|for|on|in)\s+(the\s+|a\s+|an\s+|this\s+|that\s+|my\s+|our\s+)?(\w+\s+){0,2}(heroes?|nav(igation|bar)?|sidebars?|buttons?|cards?|modals?|menus?|tabs?|panels?|pages?|screens?|components?|sections?)\b'
  polish_ui_actions='\b(polish(ing)?|refin(e|es|ed|ing)|improv(e|es|ed|ing)|enhanc(e|es|ed|ing)|elevat(e|es|ed|ing)|perfect(s|ed|ing)?|tighten(ing)?|sharpen(ing)?|beautif(y|ies|ied|ying)|level\s+up|make\s+(it|this|that|them|the)\s+(beautiful|premium|distinctive|sharper|tighter|nicer|better|polished|nicer\s+looking|more\s+(polished|distinctive|premium)))\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|dashboards?|screens?|modals?|dialogs?|drawers?|heroes?|nav(igation|bar)?|sidebars?|headers?|footers?|menus?|tabs?|panels?|layouts?|components?|empty.?states?|tables?|charts?|filters?|interfaces?|sections?|forms?|buttons?|cards?|tooltips?|toasts?|banners?|wizards?|steppers?|onboarding|app|apps|ios\s+app|iphone\s+app|ipad\s+app|mac\s+app|macos\s+app|web\s+app|websites?|sites?|uis?|product|design)\b'
  explicit_ui_terms='\b(landing.?page|modal|navbar|sidebar|tailwind|ui|ux)\b'

  if grep -Eiq "${structural_ui_actions}" <<<"${text}" \
    || grep -Eiq "${qualified_form_actions}" <<<"${text}" \
    || grep -Eiq "${visual_ui_actions}" <<<"${text}" \
    || grep -Eiq "${motion_ui_actions}" <<<"${text}" \
    || grep -Eiq "${polish_ui_actions}" <<<"${text}" \
    || grep -Eiq "${explicit_ui_terms}" <<<"${text}"; then
    return 0
  fi

  return 1
}

# infer_ui_intent — return the UI verb-class for tier mapping.
# Output is one of: build | style | polish | fix | none.
# The router uses this to inject the right tier guidance:
#   build  → Tier A (full 9-section contract)
#   style  → Tier B  (palette + typography + visual signature only)
#   polish → Tier B+ (palette + typography + signature + component states + density rhythm; NOT preserve)
#   fix    → Tier C  (preserve existing tokens; do not redesign)
#   none   → no UI work detected
# Order matters: build/redesign verbs win when both build and polish
# verbs co-occur (e.g., "build a polished landing page" → build, not polish).
infer_ui_intent() {
  local text="$1"
  [[ -z "${text}" ]] && { printf 'none'; return; }

  # Tier A — greenfield/redesign verbs
  if grep -Eiq '\b(build(ing)?|creat(e|ing)|add(ing)?|implement(ing)?|redesign(ing)?|design(ing)?|make\s+(a|an|the|my|our)?\s*(new|fresh)?)\s+' <<<"${text}"; then
    printf 'build'; return
  fi
  # Tier B — surface theming
  if grep -Eiq '\b(style|styl(e|ing)|restyle|theme(d|ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|my\s+|our\s+)' <<<"${text}"; then
    printf 'style'; return
  fi
  # Tier B+ — polish-class refinement (must not be Tier C "fix")
  if grep -Eiq '\b(polish(ing)?|refin(e|es|ed|ing)|improv(e|es|ed|ing)|enhanc(e|es|ed|ing)|elevat(e|es|ed|ing)|perfect(s|ed|ing)?|tighten(ing)?|sharpen(ing)?|beautif(y|ies|ied|ying)|level\s+up|make\s+(it|this|that|them|the)\s+(beautiful|premium|distinctive|sharper|tighter|nicer|better|polished))\s+' <<<"${text}"; then
    printf 'polish'; return
  fi
  # Tier C — preservation
  if grep -Eiq '\b(fix(ing)?|refactor(ing)?|clean\s+up|debug(ging)?)\s+' <<<"${text}"; then
    printf 'fix'; return
  fi
  printf 'none'
}

# infer_ui_platform — detect target UI platform from prompt + project profile.
# Output is one of: web | ios | macos | cli | unknown.
# Precedence (most-specific wins): cli > macos > ios > web.
# Project profile fallback only consulted when prompt has no platform signal.
# Web is the default for ambiguous UI prompts (highest base rate).
infer_ui_platform() {
  local text="$1"
  local profile="${2:-}"
  [[ -z "${text}" ]] && { printf 'unknown'; return; }

  # CLI/TUI signals (most specific)
  if grep -Eiq '\b(cli|tui|terminal\s+(app|ui|interface)|command.?line\s+(app|tool|interface)|argv|stdout|stderr|argparse|clap|cobra|click\s+(library|cli)|cobra\s+cli|charm\.sh|bubbletea|bubble\s+tea|lipgloss|lip\s+gloss|gum\s+cli|ratatui|ANSI\s+(color|escape)|exit\s+code|man\s+page|--help\s+output|fzf|ripgrep|btop|lazygit|helix\s+editor|fish\s+shell|starship\s+prompt)\b' <<<"${text}"; then
    printf 'cli'; return
  fi
  # macOS signals (more specific than iOS) — includes macOS-only SwiftUI
  # markers (MenuBarExtra, NSHostingView) and AppKit/Cocoa imports. Bare
  # SwiftUI/Swift signals are NOT here because SwiftUI is cross-platform;
  # macOS routing requires a macOS-specific marker.
  if grep -Eiq '\b(macOS\s+app|Mac\s+app|menu.?bar\s+app|MenuBarExtra|AppKit|Cocoa|Mac\s+Catalyst|NSWindow|NSToolbar|NSSplitView|NSStatusItem|NSViewController|NSApplication|NSHostingView|NSApplicationDelegate)\b' <<<"${text}"; then
    printf 'macos'; return
  fi
  # iOS signals — also catch standalone "iOS"/"iPhone"/"iPad" tokens since
  # users say "an app for iOS" / "iPhone app" / "iPad-only" without always
  # writing "iOS app" as a consecutive phrase. False-positive risk: a web
  # prompt mentioning "iOS-style design" routes to iOS — acceptable; the
  # platform mention is itself a strong intent signal. Bare "SwiftUI" is
  # intentionally NOT a signal here — SwiftUI runs on macOS too. The
  # macOS regex above catches macOS-specific SwiftUI markers; the
  # swift-ios / swift-macos profile subtype disambiguates the rest.
  if grep -Eiq '\b(iOS|iPhone|iPad|UIKit|App\s+Store|TestFlight|HIG|SF\s+Symbols|Dynamic\s+Type|Liquid\s+Glass|UITabBar|UIViewController|UINavigationController)\b' <<<"${text}"; then
    printf 'ios'; return
  fi
  # Project-profile fallback when prompt is platform-silent. Profiles are
  # comma-separated tag lists from detect_project_profile (e.g.
  # "swift,swift-macos,docs"). Order: cli > macos > ios — most specific
  # subtype wins. Bare "swift" without a target subtype defaults to iOS
  # since iOS has the higher base rate for Swift apps; the routing is
  # still "Apple native" rather than the previous web default.
  if [[ ",${profile}," == *",cli,"* ]]; then
    printf 'cli'; return
  fi
  if [[ ",${profile}," == *",macos,"* || ",${profile}," == *",swift-macos,"* ]]; then
    printf 'macos'; return
  fi
  if [[ ",${profile}," == *",ios,"* || ",${profile}," == *",swift-ios,"* ]]; then
    printf 'ios'; return
  fi
  if [[ ",${profile}," == *",swift,"* ]]; then
    printf 'ios'; return
  fi
  # Web signals
  if grep -Eiq '\b(landing.?page|website|web\s+app|browser|tailwind|next\.?js|vite|react|vue|svelte|astro|nuxt|sveltekit|remix|HTML|CSS|html\s+page|web\s+page)\b' <<<"${text}"; then
    printf 'web'; return
  fi
  # Default to web — highest base rate when is_ui_request matched but no
  # platform signal is present. Caller can override with prompt clarity.
  printf 'web'
}

# infer_ui_domain — detect product domain from prompt content.
# Output is one of: fintech | wellness | creative | devtool | editorial |
# education | enterprise | consumer | unknown.
# Domain affinity drives archetype selection (fintech → Stripe/Linear/
# Mercury, wellness → Calm/Headspace, creative → Figma/Arc, devtool →
# Linear/Raycast/Vercel, etc.). Order matters — most-specific domain wins.
infer_ui_domain() {
  local text="$1"
  [[ -z "${text}" ]] && { printf 'unknown'; return; }

  if grep -Eiq '\b(payment|invoice|wallet|bank(ing)?|crypto|trading|stripe|plaid|fintech|finance|investment|portfolio\s+(management|tracking)|accounting|budgeting|expense|payroll|tax\s+(filing|prep))\b' <<<"${text}"; then
    printf 'fintech'; return
  fi
  if grep -Eiq '\b(meditation|mindful(ness)?|therap(y|ist)|wellness|fitness|sleep|workout|yoga|breathing|nutrition|mental\s+health|self.?care|calm|headspace)\b' <<<"${text}"; then
    printf 'wellness'; return
  fi
  if grep -Eiq '\b(portfolio|gallery|artist|photo(grapher|graphy)?|videograph(y|er)|design\s+tool|canvas|illustration|creative\s+(agency|studio)|music\s+(app|player)|audio|sound\s+app)\b' <<<"${text}"; then
    printf 'creative'; return
  fi
  if grep -Eiq '\b(developer\s+tool|dev\s+tool|api\s+(client|console)|admin\s+(panel|dashboard)|monitoring|observability|debug(ging)?\s+tool|log\s+viewer|cli\s+tool|sdk|framework|library\s+for\s+developers)\b' <<<"${text}"; then
    printf 'devtool'; return
  fi
  if grep -Eiq '\b(blog|magazine|news\s+(app|site)|publication|reading\s+app|essay\s+platform|journal(ism)?|editorial|long.?form|article\s+(app|reader))\b' <<<"${text}"; then
    printf 'editorial'; return
  fi
  if grep -Eiq '\b(course|learning\s+(app|platform)|education(al)?\s+(app|tool)|tutor(ial|ing)?|classroom|student\s+(app|tool)|teacher\s+(app|dashboard)|kids\s+(app|game)|child(ren)?(\s+(app|game))?|study\s+(app|tool)|quiz\s+app|flashcard)\b' <<<"${text}"; then
    printf 'education'; return
  fi
  if grep -Eiq '\b(crm|erp|saas\s+platform|b2b|workflow\s+(tool|app)|approval\s+(flow|system)|compliance\s+(tool|dashboard)|audit\s+log|vendor\s+(portal|management)|enterprise\s+(app|portal)|admin\s+console|reporting\s+suite)\b' <<<"${text}"; then
    printf 'enterprise'; return
  fi
  if grep -Eiq '\b(social\s+(app|network)|messaging\s+app|marketplace|booking\s+(app|platform)|community\s+app|feed\s+app|chat\s+app|forum|consumer\s+app|shopping\s+app|e.?commerce|store(front)?|product\s+catalog)\b' <<<"${text}"; then
    printf 'consumer'; return
  fi
  printf 'unknown'
}

infer_domain() {
  local text="$1"
  local project_profile="${2:-}"

  local coding_score
  local writing_score
  local research_score
  local operations_score

  # --- Bigram matching: compound phrases that disambiguate domain ---
  # Action + coding-object → strong coding signal
  local coding_bigrams
  coding_bigrams=$(count_keyword_matches '\b(writ(e|ing)|add(ing)?|creat(e|ing)|run(ning)?|fix(ing)?|updat(e|ing))\s+((unit|integration|e2e|end.to.end|acceptance)\s+)?(tests?|test\s*suites?|specs?|code|functions?|class(es)?|components?|endpoints?|modules?|handlers?|middleware|routes?|migrations?|schemas?)\b' "${text}")
  coding_bigrams=${coding_bigrams:-0}

  # Action + user-facing UI-object → coding signal.
  local ui_bigrams
  ui_bigrams=$(count_keyword_matches '\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|dashboards?|screens?|modals?|dialogs?|drawers?|heroes?|nav(igation|bar)?|sidebars?|headers?|footers?|menus?|tabs?|panels?|layouts?|components?|empty.?states?|tables?|charts?|filters?|accordions?|wizards?|steppers?|banners?)\b' "${text}")
  ui_bigrams=${ui_bigrams:-0}
  coding_bigrams=$((coding_bigrams + ui_bigrams))

  # Form-building prompts are common UI work, but "form" alone is too
  # ambiguous, so require a UI-ish qualifier.
  local form_bigrams
  form_bigrams=$(count_keyword_matches '\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(login|signup|sign[- ]?up|sign[- ]?in|checkout|contact|search|settings|profile|feedback|payment|registration|onboarding|responsive)\s+forms?\b' "${text}")
  form_bigrams=${form_bigrams:-0}
  coding_bigrams=$((coding_bigrams + form_bigrams))

  local motion_bigrams
  motion_bigrams=$(count_keyword_matches '\b(add(ing)?|create|creat(e|ing)|build(ing)?|make|implement(ing)?|update(ing)?)\s+(a\s+|an\s+|the\s+|some\s+|subtle\s+|micro\s+)?animations?\s+(to|for|on|in)\s+(the\s+|a\s+|an\s+|this\s+|that\s+|my\s+|our\s+)?(\w+\s+){0,2}(heroes?|nav(igation|bar)?|sidebars?|buttons?|cards?|modals?|menus?|tabs?|panels?|pages?|screens?|components?|sections?)\b' "${text}")
  motion_bigrams=${motion_bigrams:-0}
  coding_bigrams=$((coding_bigrams + motion_bigrams))

  # Design/style + UI-object → coding signal (not general)
  local design_bigrams
  design_bigrams=$(count_keyword_matches '\b(design(ing)?|style|styl(e|ing)|redesign(ing)?|restyle|theme)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(pages?|forms?|buttons?|cards?|modals?|dialogs?|drawers?|dropdowns?|nav(igation|bar)?|sidebars?|headers?|footers?|heroes?|layouts?|components?|interfaces?|screens?|dashboards?|landing.?pages?|sections?|menus?|tabs?|panels?|empty.?states?|tables?|charts?|filters?)\b' "${text}")
  design_bigrams=${design_bigrams:-0}
  coding_bigrams=$((coding_bigrams + design_bigrams))

  # Action + writing-object → writing signal. v1.17.0 broadens the
  # pattern to allow optional article words ("a", "the", "my") and
  # 0-2 intermediary words between verb and deliverable, AND extends
  # the deliverable noun list to include operations-shaped artifacts
  # (follow-ups, recaps, briefs, action items, etc.) — these are
  # concrete written deliverables even when the noun also has an
  # operations connotation. Closes the gap where a prompt like "plan
  # the sprint and write the follow-up" scored zero on the writing leg
  # because "follow-up" was operations-only and "draft a memo" missed
  # because the previous pattern required no article between verb and
  # noun.
  local writing_bigrams
  writing_bigrams=$(count_keyword_matches '\b(writ(e|ing)|draft(ing)?|compos(e|ing)|author(ing)?|prepar(e|ing))\s+(a\s+|an\s+|the\s+|my\s+|our\s+|this\s+|that\s+|some\s+)?(\w+\s+){0,2}(papers?|essays?|reports?|emails?|memos?|articles?|letters?|proposals?|manuscripts?|blogs?\s*posts?|follow.?ups?|briefs?|responses?|repl(y|ies)|recaps?|summar(y|ies)|status.?updates?|action.?items?|action.?plans?|checklists?|notes?|minutes|updates?|messages?|posts?|wrap.?ups?|read.?outs?)\b' "${text}")
  writing_bigrams=${writing_bigrams:-0}
  local writing_topic_bigrams
  writing_topic_bigrams=$(count_keyword_matches '\b(writ(e|ing)|draft(ing)?|compos(e|ing)|author(ing)?)\s+(about|on)\b' "${text}")
  writing_topic_bigrams=${writing_topic_bigrams:-0}
  writing_bigrams=$((writing_bigrams + writing_topic_bigrams))

  # Action + research-object → research signal
  local research_bigrams
  research_bigrams=$(count_keyword_matches '\b(investigate|research|compare|analy[zs]e|evaluat(e|ing))\s+(why|how|whether|alternatives?|options?|approaches?|strategies?|tools?|frameworks?|solutions?|vendors?|platforms?)\b' "${text}")
  research_bigrams=${research_bigrams:-0}
  local research_topic_bigrams
  research_topic_bigrams=$(count_keyword_matches '\b(find|gather|collect)\s+(data|evidence|sources|information|references?)\s+(on|about|for|regarding)\b' "${text}")
  research_topic_bigrams=${research_topic_bigrams:-0}
  research_bigrams=$((research_bigrams + research_topic_bigrams))

  # Action + operations-object → operations signal
  local operations_bigrams
  operations_bigrams=$(count_keyword_matches '\b(plan|create|build|draft|prepare|make)\s+(a\s+|an\s+|the\s+|my\s+|our\s+)?(project\s+plan|roadmap|timeline|agenda|checklist|action.?plan|schedule|rollout|migration\s+plan|deployment\s+plan|release\s+plan|sprint\s+plan|backlog|kanban|standup|retro)\b' "${text}")
  operations_bigrams=${operations_bigrams:-0}
  local operations_action_bigrams
  operations_action_bigrams=$(count_keyword_matches '\b(turn|convert|transform)\s+.{0,30}\s+(into|to)\s+(a\s+|an\s+)?(action.?plan|checklist|task.?list|follow.?up|decision|memo)\b' "${text}")
  operations_action_bigrams=${operations_action_bigrams:-0}
  operations_bigrams=$((operations_bigrams + operations_action_bigrams))

  # --- Negative keywords: subtract false positives ---
  # "report" after bug/error/test/crash → coding context, not writing
  # "post" in HTTP context → not writing
  local writing_negatives
  writing_negatives=$(count_keyword_matches '\b(bug|error|test|crash|status|coverage)\s+reports?\b|\bpost\s+(requests?|endpoints?|methods?|routes?|data)\b' "${text}")
  writing_negatives=${writing_negatives:-0}

  # --- Unigram scoring ---
  local coding_strong
  coding_strong=$(count_keyword_matches '\b(bugs?|fix(es|ed|ing)?|debug(ging)?|refactor(ing)?|implement(ation|ed|ing)?|repos?(itory)?|function|class(es)?|component|endpoints?|apis?|schema|database|quer(y|ies)|migration|lint(ing)?|compile|tsc|typescript|javascript|python|swift|xcode|react|next\.?js|css|html|webhooks?|codebase|source.?code|ci/?cd|docker|container|backend|frontend|fullstack|tailwind|vue(\.?js)?|angular|svelte)\b' "${text}")
  coding_strong=$(( ${coding_strong:-0} + coding_bigrams ))

  local coding_weak
  coding_weak=$(count_keyword_matches '\b(tests?|build|scripts?|config(uration)?|hooks?|deploy(ed|ing|ment)?|server|commit(s|ted|ting)?|push(ed|ing)?|merge[dr]?|rebase[dr]?|branch(es|ed|ing)?|cherry.?pick|stash(ed|ing)?|tag(ged|ging)?)\b' "${text}")
  coding_weak=${coding_weak:-0}

  # Weak coding keywords only count when a strong signal is present,
  # OR when 3+ weak signals cluster together (multiple weak = strong).
  if [[ "${coding_strong}" -gt 0 ]]; then
    coding_score=$((coding_strong + coding_weak))
  elif [[ "${coding_weak}" -ge 3 ]]; then
    coding_score="${coding_weak}"
  else
    coding_score=0
  fi

  writing_score=$(count_keyword_matches '\b(paper|draft(ing)?|essay|article|report|proposal|email|memo|letter|statement|abstract|introduction|conclusion|outline|rewrite|polish(ing)?|paragraph|manuscript|cover.?letter|sop|personal.?statement|blog|post)\b' "${text}")
  writing_score=$(( ${writing_score:-0} + writing_bigrams - writing_negatives ))
  if [[ "${writing_score}" -lt 0 ]]; then writing_score=0; fi

  research_score=$(count_keyword_matches '\b(research(ing)?|investigate|investigation|analy(sis|ze|zing)|compare|comparison|survey|literature|sources|citations?|references?|benchmark(ing)?|brief(ing)?|recommendations?|summarize|summary|pros.?and.?cons|tradeoffs?|audit(ing)?|assess(ment|ing)?|evaluat(e|ion|ing)|inspect(ion|ing)?)\b' "${text}")
  research_score=$(( ${research_score:-0} + research_bigrams ))

  operations_score=$(count_keyword_matches '\b(plan(ning)?|roadmap|timeline|agenda|meeting|follow[- ]?up|checklist|prioriti(es|se|ze)|project.?plan|travel.?plan|itinerary|reply(ing)?|respond(ing)?|application|submission)\b' "${text}")
  operations_score=$(( ${operations_score:-0} + operations_bigrams ))

  # Project profile boost: when a project has known stack indicators,
  # add a small bonus to coding (if the project is code-heavy) or writing
  # (if docs-heavy). This acts as a tiebreaker, not a dominant signal.
  if [[ -n "${project_profile}" ]]; then
    local _tag
    local code_boost=0
    for _tag in node typescript python rust go ruby elixir swift react vue svelte next bun shell; do
      if project_profile_has "${_tag}" "${project_profile}"; then
        code_boost=$((code_boost + 1))
      fi
    done
    # Cap boost at 2 to prevent project-type from overriding clear intent
    if [[ "${code_boost}" -gt 2 ]]; then code_boost=2; fi
    coding_score=$((coding_score + code_boost))

    if project_profile_has "docs" "${project_profile}"; then
      writing_score=$((writing_score + 1))
    fi
  fi

  local max_score=0
  local primary_domain="general"

  if [[ "${coding_score}" -gt "${max_score}" ]]; then
    max_score="${coding_score}"
    primary_domain="coding"
  fi
  if [[ "${writing_score}" -gt "${max_score}" ]]; then
    max_score="${writing_score}"
    primary_domain="writing"
  fi
  if [[ "${research_score}" -gt "${max_score}" ]]; then
    max_score="${research_score}"
    primary_domain="research"
  fi
  if [[ "${operations_score}" -gt "${max_score}" ]]; then
    max_score="${operations_score}"
    primary_domain="operations"
  fi

  if [[ "${max_score}" -eq 0 ]]; then
    printf '%s\n' "general"
    return
  fi

  # Mixed-detection: two domains both clearly present at ≥ 40% ratio.
  #
  # Two regimes, with intentionally different floors:
  #   - Coding involvement (any coding_score > 0) keeps the lower
  #     historical bar — a single coding signal paired with a single
  #     writing/research/operations signal is enough. This preserves
  #     pre-v1.17.0 behavior so coding-adjacent prompts still split
  #     into coding + non-coding streams.
  #   - Pure non-coding pairs (operations + writing, research + writing,
  #     etc.) require BOTH domains to score at least 2. This avoids
  #     misclassifying a writing-dominant prompt that incidentally
  #     mentions a research/operations word ("draft a proposal for an
  #     AI-assisted research workflow") as mixed when the secondary
  #     domain is just topic flavor, not a separate work stream.
  local second_max=0
  for s in "${coding_score}" "${writing_score}" "${research_score}" "${operations_score}"; do
    if [[ "${s}" -ne "${max_score}" && "${s}" -gt "${second_max}" ]]; then
      second_max="${s}"
    fi
  done
  # Tie at the top — two or more domains at the same max — is mixed.
  local _tie_count=0
  for s in "${coding_score}" "${writing_score}" "${research_score}" "${operations_score}"; do
    [[ "${s}" -eq "${max_score}" ]] && _tie_count=$((_tie_count + 1))
  done
  if [[ "${_tie_count}" -ge 2 ]]; then
    second_max="${max_score}"
  fi

  local mixed_floor=1
  if [[ "${coding_score}" -eq 0 ]]; then
    mixed_floor=2
  fi
  if [[ "${second_max}" -ge "${mixed_floor}" && "${max_score}" -ge "${mixed_floor}" ]] \
    && [[ "$(( second_max * 100 / max_score ))" -ge 40 ]]; then
    printf '%s\n' "mixed"
    return
  fi

  printf '%s\n' "${primary_domain}"
}

# --- end P1 ---

classify_task_intent() {
  local text="$1"
  local normalized

  # If the prompt is a /ulw or /autowork skill-body expansion, classify on the
  # user's task body rather than the skill header. Without this, embedded SM
  # or advisory keywords in a quoted task body (e.g., a /ulw command pasting a
  # previous session's feedback) can mis-route an obvious execution request.
  local task_body
  if task_body="$(extract_skill_primary_task "${text}")"; then
    text="${task_body}"
  fi

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if [[ -z "${normalized}" ]]; then
    printf '%s\n' "execution"
    return
  fi

  if is_continuation_request "${text}"; then
    printf '%s\n' "continuation"
  elif is_checkpoint_request "${normalized}"; then
    printf '%s\n' "checkpoint"
  elif is_session_management_request "${normalized}"; then
    printf '%s\n' "session_management"
  elif is_imperative_request "${normalized}"; then
    printf '%s\n' "execution"
  elif is_advisory_request "${normalized}"; then
    printf '%s\n' "advisory"
  else
    printf '%s\n' "execution"
  fi
}

# --- Classifier telemetry ---
#
# Record every prompt classification to a per-session JSONL so classifier
# misfires can be detected across time. Each record is:
#   {ts, prompt_preview, intent, domain, pretool_blocks_observed}
#
# `pretool_blocks_observed` snapshots the pretool_intent_blocks counter at
# classification time. The NEXT prompt compares this against the current
# counter — if it incremented, the user attempted a destructive op and was
# blocked, which (when combined with the next prompt being execution-shaped)
# is strong evidence the classifier should have said "execution" the first
# time.
#
# Misfire detection happens in the router itself — this helper just writes
# the row.
record_classifier_telemetry() {
  local intent="$1"
  local domain="$2"
  local prompt_preview="$3"
  local blocks_before="$4"

  [[ -n "${SESSION_ID:-}" ]] || return 0
  # Opt-out: users who don't want prompt previews written to disk can set
  # classifier_telemetry=off in oh-my-claude.conf (or OMC_CLASSIFIER_TELEMETRY=off).
  [[ "${OMC_CLASSIFIER_TELEMETRY}" == "on" ]] || return 0
  local file
  file="$(session_file "classifier_telemetry.jsonl")"
  local record
  record="$(jq -nc \
    --arg ts "$(now_epoch)" \
    --arg intent "${intent}" \
    --arg domain "${domain}" \
    --arg prompt_preview "$(truncate_chars 200 "${prompt_preview}")" \
    --argjson blocks "$(printf '%d' "${blocks_before:-0}")" \
    '{
      ts: $ts,
      intent: $intent,
      domain: $domain,
      prompt_preview: $prompt_preview,
      pretool_blocks_observed: $blocks
    }')"
  printf '%s\n' "${record}" >> "${file}"

  # Cap at 100 rows per session to keep the file small under heavy use.
  local line_count
  line_count="$(wc -l < "${file}" 2>/dev/null || echo 0)"
  line_count="${line_count##* }"
  if [[ "${line_count}" -gt 100 ]]; then
    tail -n 100 "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  fi
}

# detect_classifier_misfire: look at the most recent telemetry row and the
# current (prompt, current_blocks) tuple. If the prior classification looks
# like a false-negative on execution, append a "misfire" annotation row.
#
# Counter semantics: `pretool_intent_blocks` is cumulative across the
# session — prompt-intent-router resets `stop_guard_blocks`,
# `session_handoff_blocks`, `advisory_guard_blocks`, and `stall_counter`
# on every UserPromptSubmit, but NOT `pretool_intent_blocks`. That's
# deliberate: the misfire detector needs a monotonic clock so it can
# compute a *delta* between the snapshot taken at classification time
# and the current value. If we reset the counter each turn, every block
# would look like "incremented by 1 since last turn" and we'd lose the
# ability to distinguish "block fired in this turn" from "no block
# fired in this turn."
#
# Signals:
#   (a) Prior intent was non-execution (advisory|session_management|checkpoint)
#       AND pretool_intent_blocks delta > 0 in the window → user's
#       prior turn attempted a destructive op and got blocked. High-
#       confidence misfire.
#   (b) Prior intent was non-execution AND current prompt is a bare affirm
#       (yes/do it/proceed/go ahead/yes please) AND a pretool block fired
#       in the window → user is confirming the prior intent was execution.
#
# The misfire annotation is a separate line (not an in-place update) so the
# telemetry file stays append-only — easier to diff, easier to audit, no
# write-race with concurrent hooks.
detect_classifier_misfire() {
  local current_prompt="$1"
  local current_blocks="$2"

  [[ -n "${SESSION_ID:-}" ]] || return 0
  # Respect the classifier_telemetry opt-out. Detection reads the file
  # that record_classifier_telemetry writes, so if recording is off the
  # detector has nothing to work with either.
  [[ "${OMC_CLASSIFIER_TELEMETRY}" == "on" ]] || return 0
  local file
  file="$(session_file "classifier_telemetry.jsonl")"
  [[ -f "${file}" ]] || return 0

  # Read the most recent non-misfire row.
  local prior_row
  prior_row="$(grep -v '"misfire":' "${file}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${prior_row}" ]] || return 0

  local prior_intent prior_blocks prior_ts
  prior_intent="$(jq -r '.intent // empty' <<<"${prior_row}" 2>/dev/null || true)"
  prior_blocks="$(jq -r '.pretool_blocks_observed // 0' <<<"${prior_row}" 2>/dev/null || echo 0)"
  prior_ts="$(jq -r '.ts // empty' <<<"${prior_row}" 2>/dev/null || true)"

  # Skip if prior was already execution/continuation — nothing to correct.
  case "${prior_intent}" in
    advisory|session_management|checkpoint) ;;
    *) return 0 ;;
  esac

  # Staleness guard: if the prior row is more than 15 minutes old, the
  # user likely walked away and came back — any pretool_intent_blocks
  # delta we see may reflect a block that fired long before this prompt
  # and is no longer the "prior attempt" the current prompt is responding
  # to. 900 seconds mirrors the post-compact-bias decay window used by
  # prompt-intent-router so the two staleness signals stay in sync.
  if [[ -n "${prior_ts}" ]] && [[ "${prior_ts}" =~ ^[0-9]+$ ]]; then
    local age_seconds=$(( $(now_epoch) - prior_ts ))
    if [[ "${age_seconds}" -ge 900 ]]; then
      log_hook "classifier-telemetry" "suppressing misfire: prior row is ${age_seconds}s old (>900s)"
      return 0
    fi
  fi

  local blocks_increment=$(( current_blocks - prior_blocks ))
  if [[ "${blocks_increment}" -le 0 ]]; then
    # No PreTool blocks fired in the prior window — no evidence of misfire.
    return 0
  fi

  local trimmed
  trimmed="$(trim_whitespace "${current_prompt}")"

  # Negation filter: if the user's current prompt explicitly walks back
  # the prior attempt ("no", "don't", "stop", "cancel", "abort", "never
  # mind", "actually no", "that was wrong"), the block was correct —
  # the prior intent really was advisory, and the user is affirming
  # that now. Do not log as a misfire.
  if printf '%s' "${trimmed}" \
      | grep -Eiq '^(no(pe)?|don.?t|do[[:space:]]+not|stop|cancel|abort|wait|hold[[:space:]]+on|never[[:space:]]+mind|nevermind|actually[[:space:]]+no|that.?s[[:space:]]+wrong|that[[:space:]]+was[[:space:]]+wrong)([[:space:][:punct:]]|$)'; then
    log_hook "classifier-telemetry" "suppressing misfire: current prompt negates prior attempt"
    return 0
  fi

  # Signal (a) always applies when blocks fired in a non-execution window.
  # Signal (b) is a bonus: affirmation-shaped current prompt tightens the
  # inference. Either way, we log the misfire because the block itself is
  # evidence the user tried to execute.
  local reason="prior_non_execution_plus_pretool_block"
  # Affirmation detection: short prompts that confirm the prior intent was
  # execution. Matches bare words ("yes"), common combinations ("yes do
  # it", "yeah please"), and verbs-of-assent ("proceed", "go ahead").
  # Length-bounded to 60 chars so a long re-explanation doesn't get
  # mistaken for an affirmation.
  if [[ "${#trimmed}" -le 60 ]] \
      && printf '%s' "${trimmed}" \
      | grep -Eiq "^([[:space:]]*(yes|yep|yeah|sure|ok(ay)?|y)([[:space:][:punct:]]+(please|sir|ma'?am|do|it|go|ahead|run|proceed|commit|push|tag|ship|please[[:space:]]+do))*|do[[:space:]]+it|proceed|go[[:space:]]+ahead|go[[:space:]]+for[[:space:]]+it|please[[:space:]]+do|confirm(ed)?|run[[:space:]]+it|ship[[:space:]]+it)[[:space:].!]*$"; then
    reason="prior_non_execution_plus_affirmation_and_pretool_block"
  fi

  local record
  record="$(jq -nc \
    --arg ts "$(now_epoch)" \
    --arg prior_ts "${prior_ts}" \
    --arg prior_intent "${prior_intent}" \
    --arg reason "${reason}" \
    --argjson blocks "${blocks_increment}" \
    '{
      misfire: true,
      ts: $ts,
      prior_ts: $prior_ts,
      prior_intent: $prior_intent,
      reason: $reason,
      pretool_blocks_in_window: $blocks
    }')"
  printf '%s\n' "${record}" >> "${file}"
  log_hook "classifier-telemetry" "misfire detected: prior=${prior_intent} reason=${reason}"
}

is_execution_intent_value() {
  local intent="$1"

  case "${intent}" in
    execution|continuation)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
