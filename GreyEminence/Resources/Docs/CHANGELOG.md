# Changelog

All notable changes are listed here, newest first. Recent releases have
full detail; older ones are summarized. The version number tracks
`MARKETING_VERSION` in `project.yml`.

## 0.32.5 — 2026-09-03

**A new speaker's first words no longer go to the previous speaker**
- The diarizer decides who said each turn knowing only the voices it has
  heard so far, so the first thing a new person says landed on whoever
  they sounded most like at the time. In a team sync, Paras's opening
  sentences were filed under Carlos; his own cluster only existed from
  his second turn on.
- Once a meeting has been fully heard, every turn is now re-checked
  against the final set of voices, and moves when it clearly matches
  another voice and clearly doesn't match its own. Short interjections
  and ambiguous turns stay where they were. This applies to
  re-transcription and to "Fix speakers in older meetings".

## 0.32.4 — 2026-09-03

**Fixing over-split speakers in older meetings**
- Settings ▸ Audio ▸ "Fix speakers in older meetings" now also handles
  meetings that show more voices than were on the call — a "Speaker 2"
  with almost nothing to say, or a stray anonymous "Speaker" beside the
  one real remote voice. It listens to the audio again and keeps the
  result only if it hears fewer voices; a meeting where the numbering
  was right is left exactly as it was. Words and timings never change,
  and it can be undone like before.
- That button had been disabled since it shipped: the scan counted the
  meetings needing repair but never kept the list. It works now.

## 0.32.3 — 2026-09-02

**A two-person call no longer shows three voices**
- The diarizer was turning one-word interjections into extra people. A
  "Yeah." or "Okay." is too little audio for a stable voice signature, so
  it landed far from the speaker who said it, seeded a new cluster, and
  then collected the rest of their backchannel — in a 25-minute 1:1 that
  produced a "Speaker 2" made of nothing but "Yeah" and "Absolutely".
  Interjections the diarizer skipped entirely were left as a third,
  anonymous "Speaker".
- A voice now needs twenty seconds of speech, not three, before it counts
  as a participant. And when only one remote voice remains, speech the
  diarizer missed goes to that voice, since there is nobody else it could
  be. With several voices it still stays unlabelled rather than guessing.
- Re-transcribe an affected meeting (Reanalyze menu) to relabel it.

## 0.32.2 — 2026-08-28

**The app no longer freezes while it tidies up**
- Three jobs ran on the thread that draws the window. The daily backup
  copied the whole database inline at launch, with nothing on screen to
  say why — so the first launch of each day simply stopped responding for
  as long as the copy took. Startup maintenance did the same while
  displaying a message saying it was running, which is worse: it looked
  like the app was working when it couldn't be used. And opening
  Developer settings measured every recording on disk before drawing
  anything.
- All three now run out of the way. The status bar names what's happening
  and how far along it is — "Startup maintenance — trimming the usage
  log", with a progress bar — instead of one unchanging sentence, so a
  job that's working looks different from one that's stuck.

## 0.32.1 — 2026-08-28

**Housekeeping after the speaker release**
- Checking whether a meeting still had audio was creating an empty
  folder for every meeting that didn't. The nightly cleanup then
  reported clearing hundreds of recordings while freeing nothing at all,
  because it was only removing folders the check had just made.
- The transcript log recorded a line every time a chunk of audio took
  the slower of two decoders — thousands a day, drowning everything
  else. It's a single total per meeting now. Nothing was being lost:
  measured against every recording on disk, the fallback recovers the
  audio in full.

## 0.32.0 — 2026-08-27

**Transcripts tell speakers apart again**
- Every meeting is re-transcribed after recording for accuracy, and that
  step was labelling lines by which microphone they came from — yours, or
  everyone else's. So no matter how many people were in the call, all of
  them appeared as a single "Speaker". It affected 359 of 429 meetings,
  175 of which had three or more attendees.
- Re-transcription now listens for who is speaking as well as what is
  said, and attributes each line to the voice that holds most of it. A
  stretch that can't be told apart still reads "Speaker" — an
  unattributed line is honest, a wrongly attributed one isn't.
- Very brief fragments — a cough, a crossfade — no longer become
  speakers of their own, which used to make a two-person call look like
  a panel.

**Repairing older transcripts**
- Settings → Audio → "Identify speakers in older meetings" listens to the
  audio again and separates the voices in transcripts recorded before
  this worked. The words and timings don't change, only who each line is
  attributed to — and because it doesn't re-transcribe, it's far quicker
  than re-processing.
- It leaves alone any meeting where you've already named a speaker, so it
  can't overwrite your own work. Meetings whose audio has passed the
  retention window can't be repaired.
- It's reversible. The previous label is kept, so "Undo speaker
  separation" puts every transcript back exactly as it was — and because
  a repaired transcript no longer looks unattributed, undoing is also
  what makes it eligible to be repaired again later.
- Search snippets are re-indexed automatically afterwards, so Ask quotes
  the new attribution rather than the old one.
- Speakers are numbered per meeting: "Speaker 1" in one meeting isn't the
  same person as in another. Recognising a voice across meetings comes
  next.

## 0.31.0 — 2026-08-26

**Ask holds a conversation**
- Ask answered one question and forgot it. It now keeps threads: ask a
  follow-up and it continues where it left off, with a conversation list
  on the left and the whole exchange in the middle.
- A follow-up that leans on what came before — "what did she say about
  that?" — is rewritten into a standalone query before the search runs,
  because the search is keyword-sensitive and the nouns live in the
  earlier turns. When that happens, the rewritten query is shown under
  your question.
- Matched snippets moved to the right-hand panel, where transcripts sit
  everywhere else in the app. They are numbered to match the citations in
  the answers: tap `[3]` and the panel scrolls to snippet 3; click the
  snippet and it opens the meeting at that moment. Filter to just the
  ones an answer actually cited, or narrow to the sources behind a single
  answer.
- Citation numbers are stable for the life of a thread, so a snippet
  found in the first question can still be cited in the tenth answer —
  and evidence an earlier answer cited is carried into later questions
  rather than being lost when the search moves on.
- Your previous Ask history is converted into single-question
  conversations, so nothing is lost.

**A setup guide for search**
- Help → Setting Up Ask explains the methods and the trade-off between
  them, what AWS profiles work and which don't, inference profiles, what
  rebuilding costs, and every error message you can actually hit — each
  one named, with what causes it and what to do. It's linked from the Ask
  settings pane, from Ask's empty state, and from any failure message,
  because those are the moments you'd want it.

**Search can now use a real embedding model**
- Settings → Ask has a Method picker. On-device stays the default; the new
  option is Amazon Titan Text Embeddings V2, running over Bedrock on the
  AWS credentials the app already uses for analysis. Apple's on-device
  embedding averages word vectors, so a question that paraphrases what
  was said — "couldn't process due to costs" against "there's no way we
  can turn this on" — has little to match on. A real sentence encoder
  does.
- Meeting text stays inside the same AWS account that already runs the
  analysis. A dedicated embedding vendor scored higher in benchmarks and
  its free tier would have covered this index outright, but it would have
  meant sending transcripts to a third party, so it is deliberately not
  offered.
- Added Cohere Embed English v3 as a second Bedrock option, and it is the
  one to pick for a large library. Titan takes a single text per request —
  the API rejects an array outright — so indexing this many chunks means
  tens of thousands of round trips, which is what drew thousands of
  throttle responses on the first attempt. Cohere takes 96 per request:
  the same work in a few hundred calls. It also distinguishes stored text
  from search queries, which Titan does not.
- Throttled requests are retried with backoff instead of being dropped,
  and the number of parallel requests now adapts — halving when the
  account throttles, widening again after a clean run — rather than being
  a fixed guess.
- Search-index coverage is counted per record rather than per meeting. A
  meeting that lost part of itself to a throttled request used to count
  as fully indexed, so nothing ever repaired it; re-indexing now embeds
  only what's missing.
- The AWS profile list now only offers profiles the app can actually
  authenticate as — SSO and access-key ones. Profiles that assume a role
  or shell out to `credential_process` were listed and then failed with
  "profile not found" on the first request, which read as a bug rather
  than a property of the profile; they're now named as unselectable with
  the reason. Profiles that live only in `~/.aws/credentials` are offered
  for the first time — they always worked, they were just never listed.
- The embedding account is chosen separately from the analysis account.
  A role scoped to the Anthropic models can't invoke Titan at all, and
  the practical answer is usually a second AWS account rather than a
  policy change — so Titan gets its own profile and region, defaulting
  to whatever Settings → AI uses. A "Test connection" button embeds one
  short string and names the account it used, so a permissions problem
  turns up before a full rebuild rather than during one.
- Switching methods empties the search until the index is rebuilt —
  vectors from different models can't be compared. The picker now says so
  at the moment you switch, shows how much of the index the selected
  method has actually produced, and offers to rebuild on the spot.
- Rebuilding used to run one item at a time, which for an index this size
  meant the better part of an hour over a network. It now runs several at
  once, and embedding tokens are recorded in the AI usage ledger.

**A person's name now filters the search instead of skewing it**
- Asking "what did Stephen Smith say about X" used to return the
  passages where somebody *said* Stephen's name, not the ones where he
  discussed X — his name is a rare word, so it dominated the match, and
  speakers are labelled "Speaker 3" rather than by name, so it carried no
  attribution signal at all.
- A name recognised from your contacts now narrows the search to
  material connected to them — the meetings they attended *and*
  anywhere they are named — and is removed from the query text so the
  rest of the question drives the ranking. Both halves matter: people
  get quoted in rooms they were never in, and that relayed remark is
  often the answer. The narrowing is shown under your question.
- Full names always count. A bare first or last name counts only
  alongside an attribution cue ("what did Erin *say*", "Erin's
  *concerns*"), so "can you mark that as done" doesn't quietly restrict
  the search to a colleague named Mark. If the name matches nobody, or
  matches somebody with no meetings, the question is searched exactly as
  asked.

## 0.30.1 — 2026-08-20

**Open questions lead the report, and look like a callout**
- They used the same heading treatment as the summary, so they read as one
  more of its sections. They now sit above the summary in a bordered
  callout with its own label — what is still unresolved is what a reader
  most needs first. The contents list follows the new order.

## 0.30.0 — 2026-08-20

**Copying a summary now pastes properly into Teams**
- Copy put plain text on the clipboard, so a summary pasted into Teams
  arrived as a wall of lines where "1." was just a digit and "•" just a
  bullet character — no headings, no list, no emphasis. Copy now carries a
  formatted version alongside the plain one, so Teams, Slack, Outlook and
  Notes render numbered bold headings and real bullet lists. Anywhere that
  only takes plain text still gets the same readable text as before.
- The per-section copy button does the same for a single section.

## 0.29.3 — 2026-08-17

**Cancelled meetings no longer appear**
- A called-off meeting still showed up in "Which meeting are you
  recording?". Cancelled events are now dropped from both calendar
  sources, which also stops them being auto-linked to a recording or
  used for meeting prep.
- Detection covers both ways a cancellation arrives: the event's own
  status, and the "Canceled: …" title Exchange and Outlook substitute
  when they deliver a cancellation without changing the status the app
  can read — which is the case that was getting through.

## 0.29.2 — 2026-08-17

**Screenshots now appear while you're recording**
- The shared-screen thumbnails only ever showed on a finished meeting's
  page. During a recording you got a text list of what the AI had seen
  and no pictures. The recording view now shows the same screenshot strip
  as the meeting details page, filling in as frames are captured. The
  text list remains for the gap between a share starting and its first
  frame landing.

## 0.29.1 — 2026-08-14

**Fixed: the beachball on launch**
- Meeting auto-detection polls Core Audio to see which apps hold the
  microphone, and it was doing that on the main thread. The first poll
  after launch makes Core Audio load its plug-ins and enumerate every
  audio device, which is slow enough to freeze the window — so the app
  beachballed on startup and stuttered every five seconds afterwards.
  The poll now runs off the main thread.

**The status bar says what launch is doing**
- Checking for an interrupted recording, checking interviews and checking
  screen-share frames now name themselves in the footer the way startup
  maintenance already did. Update checks appear there too — "Checking for
  updates…", then whether one was found.

## 0.29.0 — 2026-08-14

**Choose what goes into a report**
- Export PDF now opens a sheet listing the summary's sections with a
  checkbox each, so you can leave parts out. Everything starts ticked.
- Action items, open questions, shared screens and the full transcript are
  separate switches, and only appear when the meeting actually has them.
  The transcript stays off unless you ask for it — it adds many pages.
- The template and screenshot placement pickers moved into the same sheet,
  with the template's description shown under it.

## 0.28.4 — 2026-08-13

**Fixed: the release build failed to compile**
- A test set up its scratch directory in `setUpWithError`, which is a
  nonisolated override and so cannot touch a property of a main-actor
  test case. The local toolchain allowed it; the one CI builds with did
  not, so 0.28.3 never produced a release.

## 0.28.3 — 2026-08-12

**The masthead now reaches the top of the page**
- Trajector and Matthew Purdon reports opened with a white strip above the
  coloured header band. The band now starts at the paper's edge. Pages
  after the first keep their margins, and the templates whose header is
  plain text are unaffected.

## 0.28.2 — 2026-08-12

**Fixed: the header sat in the middle of the page instead of spanning it**
- Every template's masthead was inset by exactly one page margin, so it read
  as a floating rectangle rather than a band across the top. A negative
  margin cannot escape the page's own margin — the renderer clips it — so
  the side margins now come from the page body, which leaves the masthead
  room to reach both edges. Continuation pages keep their margins.

## 0.28.1 — 2026-08-12

**Fixed: contents entries were numbered twice, and brand colours vanished**
- The contents list showed "1. 1. AI-first workflow" — an ordered list
  drawing both its own number and the styled one.
- Every background colour was being dropped on export, because printing
  omits them by default. The Trajector report was printing white text on
  white paper where its navy header should be, and every tinted panel was
  invisible.
- The Matthew Purdon template now leads with a full-bleed cream masthead
  rather than trying to tint the whole sheet, which is not something the
  PDF renderer can do.

## 0.28.0 — 2026-08-12

**The report is a summary again, and screenshots carry the story**
- Only the few screenshots that make a point in the summary are printed,
  and they sit beside the point they make. The rest are not printed at all
  — they made the report long without making it clearer, and everything
  captured is still in the app.
- Captions now say what the screenshot shows *and* what it establishes for
  that part of the summary, so a picture explains why it is on the page
  rather than restating what you can see.
- Screenshots are set inline with the summary by default. Collecting them
  at the end, cross-linked, is still available in the Export PDF menu for
  when the prose should read uninterrupted.
- Without AI configured nothing can be tied to a section, so a report keeps
  at most three screenshots spread across the meeting rather than all of
  them.

## 0.27.2 — 2026-08-12

**Fixed: captions described the meeting instead of the screenshot**
- A screenshot of a document being reviewed was captioned "Zoom call in
  progress during early discussion of the design workflow" — text taken
  from the key moment, which describes what was happening in the meeting,
  not what is in the picture. Captions now come from the screenshot's own
  description, so they name the tool, the screen and the values on it.
- The AI captioner was also only seeing the first 300 characters of each
  screenshot's description. The specifics are spread through the whole
  paragraph, so it was left describing the application window rather than
  the contents. It now sees enough to be specific, and is told outright
  that the call, the video tiles and the toolbar are chrome — caption what
  is inside them.

## 0.27.1 — 2026-08-12

**Fixed: exports were named after the AI's title, not the meeting's**
- The report title and filename used the AI-generated title in preference to
  the meeting's actual name. For a meeting linked to a calendar event that
  meant exporting under a name the app never shows, and if you had renamed a
  meeting yourself it ignored the rename entirely. Exports are now titled
  whatever the meeting is called at the moment you export it.

## 0.27.0 — 2026-08-12

**Every screenshot now says what it is and why it's there**
- Each figure gets a short caption naming what you're looking at and, where
  it relates to something the summary discusses, naming that too. Previously
  only the handful of screenshots tied to a summary section got a written
  caption; the rest carried either a bare timestamp label or the entire
  100–250 word description the vision pass had written, printed raw under
  the picture.
- The same pass that decides which screenshots belong beside which section
  now captions all of them, so this costs nothing extra.
- Without AI configured, captions fall back to the first sentence of the
  description, clipped at a word boundary, rather than the whole paragraph.

## 0.26.2 — 2026-08-12

**Fixed: improved screenshot picking didn't reach meetings you'd already exported**
- The figure-anchoring result is cached per meeting, and the only thing that
  expired it was re-running the analysis. So a meeting exported before
  today's improvements would have kept its old choices forever. Worse, the
  cached anchors named screenshots the new selection no longer picks, which
  would have quietly produced a report with no links at all.
- The cache now expires when the anchoring logic itself changes, so
  improvements land on the next export with nothing to re-run.

## 0.26.1 — 2026-08-12

**Better screenshots, and you choose where they go**
- Screenshot selection now favours actual content over the video call. It
  weighs what the frame was identified as — a slide, document, diagram,
  code, dashboard — and how much text is on it, so a gallery of faces
  loses to a slide. The AI is told the same thing explicitly: never anchor
  a frame showing only participant tiles or a speaker's camera.
- Key moments now pick the best frame *near* the moment rather than the
  nearest one, since the closest frame in time is often a cut to whoever
  was speaking.
- The Export PDF menu now lets you choose between screenshots collected at
  the end (cross-linked to the summary) and set inline with the summary.
- Sections no longer start on their own page — on real reports it left
  pages of white space and a lot of scrolling. The contents list stays.

## 0.26.0 — 2026-08-12

**Contents page, and a page per section**
- Reports now open with a linked table of contents, and each section of the
  summary starts on its own page. Contents entries are clickable in the
  exported PDF. Plain stays plain — it has neither.

**Fixed: the screenshot cross-links never appeared**
- The links between a screenshot and the part of the summary it supports
  only worked when screenshots were collected at the end, which only the
  Report template did. Every template now collects them at the end, which
  is what makes the links exist: a screenshot set inside its own section
  has nothing to link to, and the leftovers at the back had nothing to
  link back to.

## 0.25.3 — 2026-08-12

**Exports no longer overwrite each other**
- The suggested filename now carries a two-letter tag for the template it
  was made with — "Braintrust — 2026-08-12 (TJ).pdf" — so you can export
  one meeting under every theme into the same folder and compare them,
  instead of each export replacing the last. The tag is shown beside each
  template in the picker.

## 0.25.2 — 2026-08-12

**Jump between a screenshot and the part of the summary it belongs to**
- Screenshots printed in the appendix now carry a link back to the section
  they evidence, and that section links forward to them. Both work as real
  clickable links in the exported PDF, so you can read a point, jump to the
  picture, and come straight back.
- The Report template now collects every screenshot at the end and refers
  to them from the text, the way a formal report does. The other templates
  keep setting them beside the prose.

**Easier-to-read bullets**
- Summary points used an em dash as their marker, which was hard to pick
  out at a glance. Each template now uses a mark you can actually see.

## 0.25.1 — 2026-08-12

**Five report templates, and a picker**
- Export PDF is now a split button: click exports with your last-used
  template, the arrow picks a different one. Plain, Report (formal and
  numbered), Trajector, Matthew Purdon, and PurdonMoi.

**Fixed: reports exported with no screenshots at all**
- A shared screen only made it into a report if its AI session recap had
  also been generated. If that pass never ran, every screenshot from that
  share was silently dropped. Screenshots now stand on their own, and a
  share with no recap contributes a spread across its length instead.
- If a report still comes out with no figures, the activity log now says
  which reason it was.

## 0.25.0 — 2026-08-12

**Screenshots land beside the part of the summary they prove**
- Exporting a report now works out which captured screenshots are direct
  evidence for which section of the summary, and prints them there rather
  than in a lump at the end. A screenshot from roughly the same moment
  doesn't qualify — it has to actually show the thing being discussed.
- Most screenshots don't earn a place, and that's the intended outcome.
  Whatever no section claims still appears in the "Shared screens"
  appendix, so nothing you captured is thrown away.
- It costs one small text-only AI call per meeting — no images are
  uploaded, since the screenshots were already described during the
  recording. The result is cached, so switching templates or exporting
  the same meeting again is free. Re-running the analysis recomputes it.
- Shows up in AI Usage under a new "Reports" group.
- If AI isn't configured, or the call fails, the report still exports with
  its figures in the appendix.

## 0.24.3 — 2026-08-12

**Export a meeting as a PDF report**
- Meeting Intelligence has an "Export PDF" button. It turns the summary,
  action items, open questions and shared screens into a proper paginated
  document you can send to someone who doesn't run Grey Eminence — real
  pages, selectable text, and screenshots embedded in the file rather than
  linked to it.
- Screenshots are chosen rather than dumped: each share session contributes
  the frames tied to the key moments the analysis already identified, and a
  figure never gets separated from its caption across a page break.
- One "Plain" template for now. Branded templates, a template picker, and
  chatting at a template to restyle it are next.

## 0.24.1 — 2026-08-12

**Fixed: Zoom's popped-out screen share was missing from the window picker**
- Zoom pins its meeting windows above the normal window level, and the
  window list quietly skipped anything up there. The main Zoom window
  showed up, the popped-out shared content never did — the one window
  you actually wanted to capture. Elevated windows are now listed.
- Zoom also had no auto-detection rules at all, so its windows were only
  ever manually selectable. A popped-out or fullscreened share is now
  detected automatically, while the meeting window itself stays
  picker-only: when nobody is sharing it is a wall of faces, and
  screenshotting that would spend your frame budget on video thumbnails.
- Every window considered for capture is now logged with its window level
  in the activity log, so a share that goes undetected can be told apart
  from one that was never offered.

## 0.24.0 — 2026-08-07

**Discord calls**
- Grey Eminence now recognizes Discord alongside Teams, Zoom, and the rest.
  Discord is different: it holds your microphone for as long as you're
  connected to a voice channel, including sitting in one alone, so
  auto-recording it would capture a lot of nothing. It asks instead —
  once per call, from the menu bar or a bar at the bottom of the window,
  so you can answer without leaving the call.
- Streams get captured like any other shared screen, as long as they're
  popped out or fullscreened. The main Discord window stays available in
  the window picker but is never captured automatically, since it would
  frame the channel list and chat rather than the stream.
- Meetings now record which app they came from, shown on the meeting row.

**Fixed: recordings that captured everyone except you**
- When another app claimed the microphone a moment after recording
  started — which is exactly what happens on an auto-started call — the
  microphone could stop feeding the recording silently. The transcript
  came back with the far end only. Capture now notices and restarts
  itself, and tells you if it can't.

**A tidier transcript toolbar**
- The controls above a transcript were crowded into one row that
  compressed everything at once in a narrow panel. Selection actions now
  take over the bar only while you're selecting, and the developer tools
  have their own strip.

## 0.23.16 — 2026-08-03

**Fixed: a month of meetings appearing to be missing**
- The Meetings list sorted its month headings alphabetically instead of by
  date, so July sat below June and looked like it had vanished. Nothing was
  ever lost — the meetings were there the whole time, just filed under the
  wrong heading order. The same slip affected January and February, and any
  other pair of months whose names sort differently than the calendar does.
- Month sections now follow the calendar, newest first.

## 0.23.15 — 2026-07-30

**Fixed: meeting analysis producing no insights**
- 0.23.14 fixed the "data couldn't be read" error and revealed the next
  one: on long meetings the model was spending its entire output budget
  reasoning and never getting to the answer, so analysis failed with "No
  text content". That reasoning step is now switched off — it was doing
  nothing for these prompts, which ask for a fixed set of fields.
- When a response does come back empty, the error now says the model hit
  its output limit rather than just reporting nothing.

**Fixed: screen shares shown under the wrong meeting**
- Selecting a different meeting could leave the previous meeting's screen
  share on screen — its images, descriptions and frame count — whenever the
  two meetings happened to have the same number of frames. Nothing was
  mis-filed: the recordings were always stored against the right meeting,
  only the panel was slow to catch up. It now follows the selection.

**Re-open What's New whenever you like**
- Help → What's New in Grey Eminence brings the update highlights back
  after you've dismissed them.

## 0.23.14 — 2026-07-29

**Fixed: meeting analysis failing with "The data couldn't be read"**
- AI analysis stopped producing insights entirely, showing only the error
  "The data couldn't be read because it is missing." The Bedrock model
  behind the Sonnet profile now returns a reasoning block ahead of its
  answer, and the app rejected the whole response rather than reading past
  it. Analysis works again; screen-share frame analysis was unaffected.
- The raw AI response is now written to the activity log before it's
  parsed, so a future change in response shape leaves something to
  diagnose from instead of a bare error.

## 0.23.13 — 2026-07-24

**What's New after updates**
- A curated "What's New" sheet now appears once after the app updates to a
  version you haven't seen, highlighting the headline features with a "Try
  it" link straight into each one. Skipped several versions? You get the
  union of what you missed, capped to the headline set — the full history
  stays in this changelog. New installs are suppressed (you're onboarding,
  not catching up), and the sheet sequences behind first-run setup so the
  two never stack.
- Tasteful "NEW" badges mark new affordances in context (the recording
  side-panel's Prep tab, the screen-share capture chip) and clear the first
  time you use them — catching anything you dismissed on the sheet.

**Meeting Prep beside the transcript**
- While recording, the side panel now has a Transcript / Prep toggle. Flip
  to Prep to keep carried-over unresolved tasks, open questions, and prior
  topics in view during the meeting. The toggle only appears for recurring
  meetings that have prep to show; one-off meetings keep the plain
  transcript.

**Fixes & cleanup**
- Fixed a 100% CPU / beachball regression where the attendees row's
  `ViewThatFits` rebuilt every candidate's view tree on every layout pass.
  The roster arrangement is now chosen by headcount, not measurement.
- Deleting a meeting whose audio is shared with a split sibling no longer
  leaves that meeting's screen-frame JPEGs orphaned on disk.
- Removed two per-redraw costs read from view bodies (the dashboard's
  stalled-item count and the header's edited-segment count).

## 0.17.4 — 2026-05-26

**Re-processing robustness**
- AI response parsing now salvages prose-wrapped JSON by clipping to the
  outermost `{…}` pair before decoding, instead of failing with
  Foundation's opaque "data couldn't be read because it is in the wrong
  format". Granular reasons (empty response / top-level not an object /
  underlying decode error) now flow into the meeting's re-processing
  error.
- Failed re-processing pills now show an info icon with the underlying
  error message as a tooltip, so you can see why a job failed without
  digging through the activity log.

**Follow-up questions: blockers, not paraphrases**
- The analysis prompt now requires follow-ups to be questions about
  blockers, missing information, or dependencies for the listed action
  items — or genuine gaps the meeting didn't resolve. Restating an
  action item as a question (e.g. action: "Investigate X" + follow-up:
  "Why does X happen?") is explicitly forbidden. Empty array if there
  are no real blockers.

## 0.17.3 — 2026-05-21

**Add attendees while recording**
- The recording view now has an attendee strip below the toolbar showing
  the current meeting's attendees with a + button to add more via the
  same contact picker used elsewhere. Attendees can be added or removed
  mid-recording.
- Newly added attendees are pushed into the speaker-contact mapper
  immediately so their aliases participate in auto-matching diarized
  speakers for the rest of the session.

## 0.17.2 — 2026-05-20

**Transcript section tagging**
- Tagging a phase on a transcript segment now extends to the end of the
  transcript instead of stopping at the next existing boundary. Walking
  the transcript top-to-bottom and tagging at each phase transition just
  works — later tags overwrite earlier ones in their range, so stale
  boundaries can't strand themselves mid-transcript.
- "Clear Tag From Here Onward" → "Clear All Tags From Here Onward" and
  actually clears every following segment, not just the first run.

## 0.17.1 — 2026-05-20

**Tasks: Won't Do status**
- Tasks now have a "Won't Do" state separate from "Completed". Right-click
  any task → Mark as Won't Do. Strikes the row through (like completed
  but in secondary tone) and drops it out of Pending + Stalled. Restore
  from the Won't Do section's context menu.
- New bulk action in the Tasks options menu: "Mark Stalled as Won't Do
  (N)" with confirmation. Affects whichever tasks are currently visible
  under the Mine + Unassigned / All filter, so the scope matches what
  you see on screen.
- New "Show Won't Do" toggle in the same options menu, off by default
  so the dismissed pile doesn't clutter the list.
- SchemaV16 adds `ActionItem.dismissedAt`. Lightweight migration; existing
  items keep `nil` and stay Pending.

## 0.17.0 — 2026-05-19

**Recovery & safety**
- Re-processing jobs interrupted by a crash or restart are no longer
  auto-resumed on next launch — they're marked failed with an
  "interrupted — click Retry to resume" reason. Auto-resume of a
  misbehaving job had been creating crash loops.
- Interviews left stuck in `.recording` and recovered to `.scheduled`
  on launch now carry an `interruptedAt` timestamp (SchemaV15) and
  show an orange "Interrupted" badge on the list, so a recovered
  session is visually distinct from a never-started one.
- End Interview now asks for confirmation before flipping status to
  complete. The previous one-click destructive action had no undo.

**Score All Sections gating**
- Hidden when there's no transcript (status `.scheduled` or zero
  segments). Click used to error.

**Phase timer**
- Per-phase mute button next to the timer pill on the live phase
  header. The pill stays visible; the banner + sound are silenced
  for the current phase only. Resets on the next phase.
- Phase timer pill also surfaces inline on the active row in the
  Interviews list — glance at the list to see if the current phase
  is running long without opening the live view.

**Tagging the transcript**
- Tag Phase context menu now offers "Clear Tag From Here Onward"
  alongside the single-segment clear, so the cascading-clear is
  symmetric with the cascading-tag.
- ⌘1 / ⌘2 / ⌘3 … shortcuts inside the open menu select the matching
  phase. Faster than aiming with the mouse over a long phase list.

**Activity Log**
- Search field added; filters by message and detail-payload text in
  addition to the existing category + level pickers.

**Transient activity surface**
- Two new launch-time flashes: "N re-processing job(s) interrupted —
  open meeting to retry" and "Restored N interrupted interview(s) —
  click Start to resume" so silent recovery isn't silent anymore.

## 0.16.4 — 2026-05-19

**Crash fix (the actual one — sorry)**
- v0.16.1's resumable re-processing introduced a Swift exclusivity
  violation in `HighQualityTranscriber.transcribe(...)`. The
  checkpoint-emit closure captured local vars (`completedMic`,
  `accumulatedMic`, `segments`, ...) by reference, and those same vars
  were then passed `inout` to `runChunks`. When `runChunks` invoked
  the closure mid-loop, Swift's law of exclusivity tripped — two
  active accesses to the same storage — and aborted the process.
- Refactored to bundle all mutable progress into a single
  `TranscriptionProgress` struct passed once as `inout`. The
  checkpoint emission reads from the inout binding directly, no
  outer capture, no overlapping access.
- Any user with a Meeting stuck in `reProcessingState` from a prior
  session hit this on every launch, 4-9 seconds in, with no UI feedback
  — the queue auto-resumes orphaned jobs at startup, fires the
  buggy code path, dies before painting a window. v0.16.2's
  NLEmbedding lock and v0.16.3's eager Sparkle check were both
  misdiagnoses on my part; the actual race was never NLEmbedding.

## 0.16.3 — 2026-05-19

**Update reliability**
- Force a Sparkle background appcast fetch on every launch. The default
  schedule defers the first check by a few minutes and then waits 24 h
  between checks — long enough that a user who relaunches a buggy build
  several times in a row might never see the update prompt. Now the
  prompt fires the moment a fix is available, even if the previous
  check was minutes ago. Silent when there's nothing to install.

## 0.16.2 — 2026-05-19

**Crash fix**
- App could abort mid-flight when two embedding consumers ran at the
  same time — typically the post-recording indexer and the
  re-processing re-index, or Ask + re-index. Apple's
  `NLEmbedding.vector(for:)` shares a cached singleton internally and
  isn't thread-safe; concurrent calls trip Swift's exclusive-access
  check inside CoreNLP / BNNS and `abort()` the process. Serialized at
  the framework boundary with a process-wide lock.

## 0.16.1 — 2026-05-18

**Re-processing resumes after interruption**
- The high-accuracy re-transcription pass now checkpoints after every
  chunk. If a job is interrupted — a new recording starts (yield), the
  app is restarted, or the user cancels and re-enqueues — it picks up
  from the next un-done chunk instead of restarting from zero. Progress
  is persisted to a sidecar `reprocess-checkpoint.json` in the meeting's
  recording directory; gets cleaned up automatically on success, user
  cancel, or meeting deletion.

**Interview lifecycle / recovery**
- **End Interview** button on the scorecard toolbar. Previously the only
  End control lived in the live header — unreachable when status was
  stuck at `.recording` with no live recording. Routes through a new
  `markInterviewComplete(_:)` that handles both the live path and the
  zombie-row path.
- **Resume Interview** button replaces the misleading "In Progress"
  badge when status is `.recording` but the audio engine is idle (post
  app-restart or crash). Without it the live phase board was
  unreachable and there was no path forward.
- App-launch orphan cleanup reverts any Interview row stuck in
  `.recording` back to `.scheduled`, so the regular Start button comes
  back naturally.
- Resume reuses `interview.meeting` instead of creating a fresh one —
  prevents the original audio + segments from being orphaned and stops
  foreign transcripts from landing on the interview's now-empty meeting.

**Multi-phase rescore**
- "Score All Sections" now actually scores all phases. The old path
  hard-gated on `interview.rubric` (the legacy single-rubric field,
  typically nil for multi-phase interviews) and would only ever score
  one phase. Rewritten to iterate `interview.orderedPhases` and score
  each phase's sections against the segments tagged with that phase.

**UI regressions fixed**
- Rubrics / Templates / Candidates / Test tabs stay reachable during a
  live interview. The full tab picker was previously hidden the moment
  recording started, with the Interviews tab being the only one that
  swaps to the live layout.
- Settings sidebar (General, Audio, AI, Ask, Vocabulary, Organization,
  Interview, Obsidian, Developer) is now always visible. The nested
  NavigationSplitView was collapsing its inner sidebar in some layouts,
  hiding Developer behind a chevron toggle most users wouldn't think
  to click.

**Phase-alert sounds**
- Per-threshold sound pickers (First warning / Second warning /
  Overtime) in the Interview settings tab, with a preview button for
  each. Choose from the 14 macOS system sounds. Defaults unchanged
  (Tink / Hero / Funk).

## 0.16.0 — 2026-05-15

**Phase time-box alerts**
- Per-phase countdown pill in the live interview view — shows
  `MM:SS left` at the top of the active phase, tinted green → orange →
  red as you burn through the budget. Once the clock runs out, the pill
  flips to `+MM:SS over` and flashes red so it can't be missed while
  you're focused on the candidate.
- Threshold alerts fire at 5 min remaining, 1 min remaining, and at
  overtime. Each one shows an in-app banner at the top of the live view,
  plays a system sound (`Tink` / `Hero` / `Funk`), and writes an entry
  to the Activity Log. Phases without a `targetMinutes` budget (intro,
  ad-hoc discussion) stay silent — no pill, no alerts.
- New **Interview** tab in Settings: toggle each alert independently,
  customize the lead-time minutes (1–30 for the first warning, 1–10 for
  the second), and silence the sound entirely.

**Interview scheduling**
- The interview-creation modal now has a "Scheduled for" date+time picker
  in the footer next to the Schedule button — defaults to the top of the
  next hour. Backed by a new `Interview.scheduledAt` field (SchemaV14,
  lightweight additive migration).
- The Interview list now shows the planned slot (with a 📅 glyph) when
  one was picked; older / ad-hoc interviews keep showing their creation
  timestamp.

**Candidate brief**
- The brief panel is now collapsed by default everywhere it appears
  (live phase board, scorecard phase plan). The header still shows
  Copy and Export-PDF buttons even when collapsed — so you can hand the
  prompt to the candidate mid-interview without having to expand and
  scroll past it first.

**Roles UI wording**
- Department / Team pickers say "All" / "All Teams" instead of "None" for
  the nil option — matches what the value actually means (the role isn't
  scoped to a specific department / team). The Roles browser's group
  headers follow suit: "All Departments" / "All Teams".

## 0.15.1 — 2026-05-13

**Rubric editor**
- Section-weight dividers are draggable again. The handles were rendered
  with `.position`, which silently makes a view claim its parent's full
  size — every handle was secretly sized to the whole bar, fighting for
  hit-tests, and the Form's ScrollView was eating the first drag event
  anyway. Switched to `.offset`, gave the hit area a non-transparent
  fill (clear views aren't reliably hit-testable on macOS), and bumped
  to `.highPriorityGesture` so the Form can't intercept.

## 0.15.0 — 2026-05-12

**Organization settings — Roles**
- The Roles list is now a browsable hierarchy instead of a flat list:
  roles group under their Department, and within a department under their
  Team (with a "— no team —" group, and a "No department" group for
  unassigned roles). Each department is a collapsible section with a
  role-count badge.
- A filter field at the top searches role titles, levels, teams, and
  departments — matching groups auto-expand. "Expand all" / "Collapse
  all" for bulk control.
- Click a role to expand an inline detail card: change its
  department / team / level / custom title in place, and see which
  rubrics (with their strictness) and templates are linked to it. Delete
  is in there too. Newly-added roles auto-expand and select so you land
  right on them.

## 0.14.0 — 2026-05-11

**Interview scorecard**
- Overall assessment now sits at the top of the scorecard — it's the
  headline, so it leads.
- Copy buttons on the assessment, strengths, weaknesses, and red-flags
  sections (and the text is selectable). One click to drop the AI's
  write-up into your notes / ATS / email.
- "Scored …" indicator in the scorecard header shows when the AI last
  ran (relative, with the exact timestamp on hover).
- Impressions are editable from the scorecard — tap a dot on the "You"
  row to set a trait you forgot to rate during the interview.

**Interview scoring**
- AI section scoring at interview end actually produces grades now. The
  end-of-interview pass was falling through to the live analyzer's
  intro/conclusion branch, which returns an empty score set — so a short
  interview (or one where the live loop never got a turn) finished with
  every AI grade blank. The final pass now scores every section directly
  from the transcript regardless of what the live loop accumulated.
- Sections that weren't covered are graded **F**, not left blank. A phase
  that was skipped or never reached, or a section the transcript never
  touched, now shows an F with a rationale ("This phase was not conducted
  …" / "Not discussed …") instead of an empty "—". An interviewer grade
  always wins; this only fills in genuinely ungraded sections.
- "Score All Sections" is more robust to the model echoing back a wrong
  `section_id` — the single-section pass now attributes the result to the
  section it asked about instead of dropping it on the floor.
- Phases that were planned but never started no longer get scored against
  the whole transcript — they're marked incomplete instead.

## 0.12.0 — 2026-05-11

**Recording**
- Mic-silence auto-pause no longer fires while you're just listening to a
  meeting. It used to watch only the microphone, so a quiet stretch where
  the meeting audio was playing but you weren't talking would pause *both*
  streams and lose the meeting capture. It now also requires the system
  audio to have been silent — a real device fault (mic permission revoked,
  hardware mute, input volume at zero, another app holding the mic) still
  pauses and notifies; "you're listening" does not.

**Changelog viewer**
- Rebuilt as a two-pane browser. The left rail lists every release, newest
  first, with an unread dot on versions you haven't read yet and an "N new"
  badge in the header. The right pane shows the selected release's notes on
  their own — no more scrolling through one giant blob to find what changed.
- Read tracking: scroll to the bottom of a release's notes and it's marked
  read. Short releases that fit without scrolling mark themselves read.
  There's a "Mark all read" shortcut in the rail header if you want it.

## 0.11.0 — 2026-05-08

**Interview — live phase board**
- The live phase view now shows *every* rubric section of the active phase
  at once, as compact cards (it used to surface one section at a time). The
  candidate brief sits once at the top and collapses; AI-vs-interviewer
  grade disagreement is flagged; each criterion expands inline to show its
  evidence quotes, and tapping a quote jumps the transcript.

**Interview — notes panel**
- Rebuilt around the active phase. A phase banner sits up top; the composer
  is a multi-line field, auto-focused when you switch to the Notes tab.
  Keyboard-first sentiment: `↩` neutral, `⌘↩` "wow", `⇧↩` red-flag, `⇥`
  toggles "next note is a sub-note". Past phases collapse below a divider;
  the Notes tab badge counts notes for the active phase.

**Recording**
- Vocabulary booster actually works now. The per-term boost slider was
  stored but never read by the rescorer; it's now used as the term's
  context-biasing weight, and the string-similarity floor relaxes for
  high-boost terms so near-homophones (e.g. "Erin" ↔ "Aaron") can win.
- The elapsed-time timer runs in `.common` run-loop mode so it keeps
  ticking while a SwiftUI menu is open — opening a phase-icon dropdown
  used to freeze the timer and look like a recording pause.

**Internal**
- Shared `CriterionStatus` icon/colour styling; rubric-section and
  criterion-evaluation lookups moved onto the view model.

## 0.10.0 — 2026-05-07

**Interview templates (V9)**
- New `InterviewTemplate` concept: a reusable, named, role-scoped plan
  that composes rubrics into the loop you actually run. Distinct from
  rubrics (which define *what* to evaluate). Templates live under a new
  Templates hub tab.
- New interview creation modal launched from the Interviews tab (+
  button or ⌘N). Two-pane layout: template rail on the left (Recent /
  Templates / Role-linked rubrics palette), editable phase pane on the
  right. Drag a rubric from the rail onto the phases; click a template
  to adopt its phases as the spine, then add/remove/reorder freely.
- "New Interview" tab removed — creation lives in the modal.
- Default templates seeded on first run: Standard Interview, Backend
  Loop, Frontend Loop. Rubric refs resolve via fuzzy name match against
  the user's existing rubrics.
- Scorecard header shows "scheduled from template X" when applicable.
- Per-phase target minutes (soft time-box) are part of the template and
  carry through into scheduled phases.

**Interview workflow**
- Per-phase scorecard. Each phase (Intro / System Design / etc.) gets its
  own card with a composite grade and its rubric sections nested inside.
- Dual AI + human impressions. `InterviewImpression.aiValue` is a separate
  field; the AI no longer clobbers the interviewer's manual rating. The
  live strip and scorecard render solid dots for "You" and hollow for "AI".
- Phase-tagged notes. Each note inherits the active phase; the live notes
  panel groups by phase header.
- Per-phase icon picker (`InterviewPhase.iconName`, curated catalog) so
  System Design / Coding / Take-home are glance-distinguishable.
- Two-stage interview start: "Ready to interview" schedules without
  recording; "Start Interview" on the scorecard begins capture.
- Candidate brief at the rubric (phase) level, with a markdown editor
  (formatting controls + live preview), plus Copy and PDF export.
- Resume summarization + DnD-style character sheet driven by AI;
  resume↔interview contradictions surface as red flags during scoring.
- Many-to-many Rubric ↔ Role with per-link strictness metadata.
- Test tab rescores past interviews against any rubric (was meeting-based).

**Recording**
- Mic-silence auto-pause no longer trips spuriously across 30s windows —
  the check uses the just-computed window average and requires at least
  one buffer. (Further hardened in 0.12.0.)
- Configurable audio retention: auto-deletes audio files for completed
  meetings older than the configured threshold; transcripts always stay.

**Settings / misc**
- Developer Settings: database size reads the actual ModelContainer config
  URL instead of guessing; schema version is read live.
- Help menu surfaces README, CONTRIBUTING, CHANGELOG, and the MIT LICENSE
  inside the app.
- Schema migrations through V8: rubric brief moved from section to rubric;
  AI impression value; per-note phase; per-phase icon. All lightweight.

## 0.9.x

- Stable mic + system audio capture and on-device transcription.
- Activity Log surfaced in the sidebar; idempotent seeders.
- Sparkle auto-update wired with sandbox-friendly entitlements.
- Obsidian vault export.
- Initial interview / rubric / candidate flow.

## Earlier

Pre-0.9 work covered the core foundations: SwiftData store + versioned
schemas, FluidAudio diarization, WhisperKit transcription, Claude API
client and prompt scaffolding, NavigationSplitView shell with inspector
panel.
