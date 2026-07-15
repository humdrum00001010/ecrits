# Ecrits

Ecrits is a local-first document workspace with an AI collaborator beside the
editor. Open a folder from your computer, work on its documents directly, and
ask Codex or Claude to inspect or change them without uploading the workspace to
a separate Ecrits library.

Your files remain the source of truth. Ecrits reads from and saves back to the
folder you opened.

Local-first describes Ecrits storage, not an offline AI guarantee. When you use
Codex or Claude, that provider may receive prompts and the context its CLI reads
under the provider's own terms.

## The workspace

```text
+----------------------+-----------------------------+----------------------+
| Workspace files      | Document editor             | AI collaborator      |
|                      |                             |                      |
| Browse and open      | Read, search, format,       | Ask questions, pick  |
| local documents      | and edit the active file    | a model and control  |
|                      |                             | its write access     |
+----------------------+-----------------------------+----------------------+
```

The three panels can be resized. The editor can also be expanded to full screen
when you want to focus on the document.

## Start Ecrits locally

The repository pins its Erlang and Elixir versions with `mise`. Set the local
application URL once in `.env`:

```dotenv
APP_BASE_URL=http://localhost:4000
```

Then install the toolchain and dependencies and start the application:

```sh
mise install
mise exec -- mix setup
mise exec -- mix phx.server
```

Open [localhost:4000](http://localhost:4000) in your browser.

The document editor works without an AI provider. To use the collaborator,
install and sign in to at least one supported CLI before starting Ecrits:

```sh
codex login
# or
claude auth login
```

## A typical editing session

### 1. Open a workspace

Choose **Open folder...** or enter an absolute folder path. Ecrits opens that
folder as the workspace; it does not move the folder or create a second document
library.

### 2. Open or import a document

Select a document in **Workspace files** to open it in the center editor. You can
keep several documents open and switch between their tabs.

To bring in a file from elsewhere, use the paperclip button beside **Send** in
the collaborator. Ecrits copies the selected file into the workspace, gives the
copy a non-conflicting name when necessary, and opens it.

Ecrits recognizes:

| Documents | Experience |
| --- | --- |
| HWP and HWPX | Native document editor |
| DOC, DOCX, XLS, XLSX, PPT, PPTX, and RTF families | Office editor when the local LibreOfficeKit runtime is available |
| Markdown (`.md`) | Source editor with a rendered preview |

### 3. Edit directly or ask the collaborator

Use the document toolbar and canvas for direct edits. Useful shortcuts include:

- `Cmd+F` / `Ctrl+F` to search the active document
- `Cmd+S` / `Ctrl+S` to save immediately
- **Pick document element** in the document header to attach a precise passage
  or object to your next message

The collaborator always receives the workspace as its working context. Choose a
provider, model, reasoning level, and access level above the message box:

- **Read only** — inspect the workspace while write tools remain gated
- **Ask** — request approval before writing local files
- **Full workspace** — allow writes inside the opened workspace without asking
  for each tool call

Try prompts such as:

```text
Summarize the active contract and list dates or amounts that are still missing.

Change the notice period in the selected clause from 30 days to 45 days.

Compare the two open documents and explain the substantive differences.

Create a revised copy named nda-final.hwpx and apply the agreed changes there.
```

Agent activity, tool calls, document previews, and results appear in the same
right-hand conversation.

### 4. Confirm the save

An edited tab shows an unsaved indicator. Ecrits automatically saves a dirty
document after four seconds without another edit; you can also save immediately
with `Cmd+S` or `Ctrl+S`. Direct edits and collaborator edits follow this same
save path and update the file in the workspace.

Because the original workspace file is updated in place, keep important folders
under version control or use your normal backup practice.

## Structured document mount

The document-mount button in the header is an optional advanced workflow. When
enabled, Ecrits exposes supported workspace documents as editable JSONL files
under `.ecrits/mount/` using FSKit on macOS or FUSE on Linux. This lets a
file-oriented agent work with structured document content while Ecrits writes
valid changes back to the native file. Normal canvas and collaborator editing do
not require you to work with these files directly.

## Development checks

Run the project gate before submitting changes:

```sh
mise exec -- mix precommit
```
