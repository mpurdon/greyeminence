# Setting up Ask

Ask answers questions about your past meetings by finding the passages that
bear on them, then reading those passages back to you with citations. Finding
the right passages is the hard part, and that is what the **search method**
controls.

The method, the account it runs on, and the connection test live in
**Settings → AI → Search embeddings**, alongside every other model the app
calls. Index status and **Reindex all meetings** are in **Settings → Ask**.

---

## Choosing a method

### On-device (the default)

Apple's built-in sentence embedding. Nothing leaves your Mac, there is nothing
to configure, and it costs nothing.

Its weakness is paraphrase. It averages word vectors, so it matches questions
that reuse the words that were actually spoken. Ask *"what did we decide about
the migration"* and it does fine. Ask *"what couldn't we process because of
cost"* about a meeting where someone said *"there's no way we can turn this
on"* and it will probably miss — those two phrasings share almost no words.

If your questions tend to quote the meeting, this is enough. If they tend to
describe it in your own words, it will frustrate you.

### AWS Bedrock — Cohere Embed English v3

The one to pick for a large library. A trained sentence encoder, so a question
phrased nothing like the answer still matches. It also embeds 96 passages per
request, which matters more than it sounds: indexing a few hundred meetings
means a few hundred requests instead of tens of thousands, so a rebuild takes
minutes rather than an hour and rarely runs into rate limits.

It distinguishes *stored text* from *search queries* — a real advantage for
retrieval that the other options don't have.

### AWS Bedrock — Titan Text Embeddings V2

Also a real encoder, and a reasonable choice. The catch is that Titan accepts
one passage per request, so a full rebuild is one request per passage. On a
large library that is slow and likely to hit rate limits. Prefer Cohere unless
your account only has Titan enabled.

### Voyage AI

Listed but not enabled. It benchmarks well, but it would send meeting
transcripts to a third-party vendor. The Bedrock options keep your text inside
an AWS account you already control, which is the reason they were chosen.

---

## Setting up Bedrock

### 1. An AWS profile the app can use

Ask reads `~/.aws/config` and `~/.aws/credentials`. Two kinds of profile work:

| Profile type | Works | Why |
|---|---|---|
| **AWS SSO** (`sso_start_url` / `sso_session`) | Yes | The app reads your cached SSO token |
| **Access key** (in `~/.aws/credentials`) | Yes | Read directly |
| **Assume-role** (`role_arn` + `source_profile`) | Not yet | Needs an STS call the app doesn't make |
| **`credential_process`** | Usually not | See *external credential helpers* below |

Profiles the app can't authenticate as are listed underneath the picker with
the reason, rather than being offered and failing later.

If you edit `~/.aws` while the app is open, press **Refresh profiles**.

The first time, the app needs permission to read `~/.aws` at all — use
**Locate** in *Settings → AI* to point it there.

### 2. Which account

The embedding account is chosen separately from the one used for meeting
analysis, because they often differ: a role scoped to the Claude models will
be refused when it tries to invoke an embedding model. The **AWS account**
picker offers the **main AI account** (the profile at the top of Settings →
AI), **same as screen-frame analysis** — so two features share one account
without naming it twice — or any profile from `~/.aws`. The line beneath it
shows what that resolves to right now.

Selecting a profile adopts its configured region. Change it afterwards if the
model is enabled somewhere else — a valid account pointed at the wrong region
is the most common setup mistake.

### 3. Model access

The model has to be enabled for the account, and the role has to be allowed to
invoke it. In the AWS console: **Bedrock → Model access**.

If your organisation routes Bedrock through **application inference profiles**,
the role usually cannot invoke a model by its plain id at all. Paste the
profile ARN into the **Inference profile ARN** field. The ARN is remembered per
model, so switching methods won't send one model's profile to another. Leave it
blank if you invoke models directly.

### 4. Test the connection

Press **Test connection** before anything else. It embeds a single short string
— a fraction of a cent — and reports the vector size and which account and
region it used. It refuses to touch your existing index, so a failure here
costs nothing.

Do this before switching methods. It is much better to find a permissions
problem in one request than partway through a rebuild.

---

## Rebuilding the index

Vectors made by different models cannot be compared, so **changing the method
means rebuilding**. Until that finishes, Ask will find little or nothing.

Two things rebuild it:

- **Automatically.** Shortly after each launch the app looks for meetings
  missing passages for the current method and indexes them, showing progress
  in the footer. It picks up where it left off, so you can quit mid-rebuild.
- **Settings → Ask → Reindex all meetings.** Does the same thing on demand,
  and afterwards removes passages left by any previous method.

**Indexed with this method** next to the total is the number to watch. The
total counts everything ever indexed; only the first number is searchable now.

Rebuilding embeds only what is missing, so re-running after an interruption is
cheap.

### What it costs

Roughly one passage per paragraph of transcript. A few hundred meetings is on
the order of five million tokens — cents at current Bedrock rates. Embedding
usage is recorded in *Settings → AI Usage* under **Search index**.

---

## When something goes wrong

The Activity Log (*Settings → Developer → Activity Log*) records the provider's
exact error.

**"No AWS profile this app can authenticate as."**
No SSO or access-key profile was found. Assume-role and `credential_process`
profiles don't count — see the table above. Check that *Settings → AI* has been
pointed at your `~/.aws` directory.

**"SSO token expired."**
Run `aws sso login --profile <name>` in a terminal, then **Refresh profiles**.
SSO sessions typically last a day.

**"not authorized to perform: bedrock:InvokeModel"**
The account can reach Bedrock but this role may not use that model. Either
enable it for the role, use a different account, or — if your organisation uses
inference profiles — paste the profile ARN.

**"Too many requests"**
Rate limiting. The app retries with a widening pause and reduces how many
requests it makes at once, so this normally resolves itself. Persistent
throttling usually means Cohere is the better choice, because it needs far
fewer requests for the same work.

**Ask finds nothing after switching methods**
The rebuild hasn't finished. Check **Indexed with this method** and the footer.

**A meeting seems missing from search**
Open it and use **Index for search** in its header. The automatic sweep should
catch it at the next launch, but this does it now.

### External credential helpers

Some profiles fetch credentials by running another program
(`credential_process`). Grey Eminence is sandboxed, which means it can only
launch a program you have explicitly pointed it at — and macOS may refuse even
then.

If the selected profile uses one, **Locate credential helper…** appears; choose
the program and try again. If it is still refused, the sandbox is not going to
allow it, and the practical answers are an SSO profile, an access-key profile,
or having the helper write credentials into `~/.aws/credentials` itself.

---

## Getting better answers

- **Name people.** Mention someone in your question and Ask narrows to meetings
  they attended *and* passages where they're named, then ranks on the rest of
  your question. The narrowing is shown beneath what you asked.
- **Follow up rather than restarting.** A follow-up is rewritten into a
  standalone search before it runs, so "what was her concern?" works. The
  rewritten query is shown when it differs.
- **Use the date filter** when you know roughly when something happened.
- **Check the sources.** Every answer cites the passages behind it; click a
  citation to see the passage, or the passage to open that moment in its
  meeting. If the answer looks wrong, the sources will usually show why.
