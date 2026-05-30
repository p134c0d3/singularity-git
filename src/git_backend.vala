using GLib;
using Gee;

namespace Singularity.Apps.Git {

    // ── Data models ─────────────────────────────────────────────────────────

    public class CommitInfo : Object {
        public string hash;          // full sha
        public string short_hash;
        public string subject;
        public string author_name;
        public string author_email;
        public string date_iso;
        public string relative_date;
        public string[] parents;     // parent shas
        public string[] refs;        // decorations: branch/tag names
        // Graph lane assignment, filled by the grapher.
        public int lane = 0;
        public int[] parent_lanes = {};
    }

    public class BranchInfo : Object {
        public string name;          // e.g. "main" or "origin/main"
        public bool is_remote;
        public bool is_current;
        public string upstream;      // tracking branch, may be ""
        public int ahead;
        public int behind;
        public string tip;           // sha of tip
    }

    public enum FileState {
        UNTRACKED, MODIFIED, ADDED, DELETED, RENAMED, CONFLICTED, TYPECHANGE
    }

    public class FileChange : Object {
        public string path;
        public string orig_path;     // for renames
        public FileState state;
        public bool staged;
        public bool conflicted;
    }

    public class StatusReport : Object {
        public Gee.ArrayList<FileChange> staged = new Gee.ArrayList<FileChange>();
        public Gee.ArrayList<FileChange> unstaged = new Gee.ArrayList<FileChange>();
        public Gee.ArrayList<FileChange> untracked = new Gee.ArrayList<FileChange>();
        public Gee.ArrayList<FileChange> conflicts = new Gee.ArrayList<FileChange>();
        public string branch = "";
        public int ahead = 0;
        public int behind = 0;
        public bool has_conflicts { get { return conflicts.size > 0; } }
    }

    public class GitResult : Object {
        public bool ok;
        public string stdout_text;
        public string stderr_text;
        public int exit_code;
    }

    /**
     * One open repository. All git operations go through the `git` CLI via
     * GLib.Subprocess (async), so there are no extra library dependencies.
     */
    public class GitRepo : Object {
        public string path { get; private set; }   // working tree root
        public string display_name { get; private set; }

        public signal void changed();   // emitted after any mutating op

        public GitRepo(string root) {
            this.path = root;
            this.display_name = Path.get_basename(root);
        }

        /** True if `dir` is inside a git work tree; returns the toplevel. */
        public static async string? discover(string dir) {
            var r = yield run_in(dir, { "git", "rev-parse", "--show-toplevel" });
            if (r.ok) {
                string top = r.stdout_text.strip();
                if (top != "") return top;
            }
            return null;
        }

        // ── Core async runner ─────────────────────────────────────────────
        public async GitResult run(string[] argv) {
            return yield run_in(path, argv);
        }

        // PATH with the user's bin dirs guaranteed present, so a git in
        // ~/.local/bin is found even under a minimal session PATH.
        private static string augmented_path() {
            string home = Environment.get_home_dir();
            string cur = Environment.get_variable("PATH") ?? "";
            string[] wanted = {
                Path.build_filename(home, ".local", "bin"),
                Path.build_filename(home, "bin"),
                "/usr/local/bin", "/usr/bin", "/bin"
            };
            var parts = new Gee.ArrayList<string>();
            foreach (var w in wanted) parts.add(w);
            foreach (var p in cur.split(":"))
                if (p != "" && !parts.contains(p)) parts.add(p);
            return string.joinv(":", parts.to_array());
        }

        public static async GitResult run_in(string cwd, string[] argv) {
            var res = new GitResult();
            try {
                var launcher = new SubprocessLauncher(
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                launcher.set_cwd(cwd);
                // Disable interactive prompts / pagers.
                launcher.setenv("GIT_PAGER", "cat", true);
                launcher.setenv("GIT_TERMINAL_PROMPT", "0", true);
                launcher.setenv("LC_ALL", "C", true);
                // Ensure git is found even when the desktop session launches us
                // with a trimmed PATH: prepend the user's ~/.local/bin and the
                // common user bin dirs so a user-installed git is picked up.
                launcher.setenv("PATH", augmented_path(), true);
                var proc = launcher.spawnv(argv);
                string? out_buf, err_buf;
                yield proc.communicate_utf8_async(null, null, out out_buf, out err_buf);
                res.stdout_text = out_buf ?? "";
                res.stderr_text = err_buf ?? "";
                res.exit_code = proc.get_exit_status();
                res.ok = proc.get_successful();
            } catch (Error e) {
                res.ok = false;
                res.stderr_text = e.message;
                res.exit_code = -1;
            }
            return res;
        }

        // ── Log / graph ────────────────────────────────────────────────────
        // Uses a unit-separated pretty format so subjects with any chars are safe.
        public async Gee.ArrayList<CommitInfo> log(int max = 400, string? rev = null) {
            var list = new Gee.ArrayList<CommitInfo>();
            // %x1f = unit separator, %x1e = record separator
            string fmt = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%ar%x1f%D%x1f%s%x1e";
            string[] argv = {
                "git", "log", "--all", "--date-order",
                "--max-count=" + max.to_string(),
                "--pretty=format:" + fmt
            };
            if (rev != null) {
                argv = { "git", "log", "--max-count=" + max.to_string(),
                         "--pretty=format:" + fmt, rev };
            }
            var r = yield run(argv);
            if (!r.ok) return list;
            foreach (var rec in r.stdout_text.split("\x1e")) {
                string rrec = rec.strip();
                if (rrec == "") continue;
                var f = rrec.split("\x1f");
                if (f.length < 9) continue;
                var c = new CommitInfo();
                c.hash = f[0];
                c.short_hash = f[1];
                c.parents = f[2].strip() == "" ? new string[0] : f[2].strip().split(" ");
                c.author_name = f[3];
                c.author_email = f[4];
                c.date_iso = f[5];
                c.relative_date = f[6];
                c.refs = parse_refs(f[7]);
                c.subject = f[8];
                list.add(c);
            }
            assign_lanes(list);
            return list;
        }

        private string[] parse_refs(string deco) {
            // deco like "HEAD -> main, origin/main, tag: v1"
            var outl = new Gee.ArrayList<string>();
            foreach (var part in deco.split(",")) {
                string p = part.strip();
                if (p == "") continue;
                if (p.has_prefix("HEAD -> ")) p = p.substring(8);
                else if (p == "HEAD") continue;
                else if (p.has_prefix("tag: ")) p = "🏷 " + p.substring(5);
                outl.add(p);
            }
            return outl.to_array();
        }

        // Simple lane assignment for a left-to-right commit graph.
        private void assign_lanes(Gee.ArrayList<CommitInfo> commits) {
            // active_lanes[i] = sha expected next in lane i
            var active = new Gee.ArrayList<string>();
            foreach (var c in commits) {
                int lane = active.index_of(c.hash);
                if (lane < 0) {
                    // find a free slot
                    lane = active.index_of("");
                    if (lane < 0) { active.add(c.hash); lane = active.size - 1; }
                    else active[lane] = c.hash;
                }
                c.lane = lane;
                // This lane now expects the first parent; extra parents take new lanes.
                if (c.parents.length == 0) {
                    active[lane] = "";
                } else {
                    active[lane] = c.parents[0];
                    for (int p = 1; p < c.parents.length; p++) {
                        int pl = active.index_of("");
                        if (pl < 0) { active.add(c.parents[p]); }
                        else active[pl] = c.parents[p];
                    }
                }
            }
        }

        // ── Branches ─────────────────────────────────────────────────────────
        public async Gee.ArrayList<BranchInfo> branches() {
            var list = new Gee.ArrayList<BranchInfo>();
            // refname (full) | short | HEAD | upstream | track | objectname | symref
            string fmt = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track)%1f%(objectname)%1f%(symref)";
            var r = yield run({ "git", "for-each-ref",
                "--format=" + fmt, "refs/heads", "refs/remotes" });
            if (!r.ok) return list;
            foreach (var line in r.stdout_text.split("\n")) {
                if (line.strip() == "") continue;
                var f = line.split("\x1f");
                if (f.length < 7) continue;
                // Skip symbolic refs like refs/remotes/origin/HEAD -> .../master.
                if (f[6].strip() != "") continue;
                var b = new BranchInfo();
                b.name = f[1];
                b.is_remote = f[0].has_prefix("refs/remotes/");
                b.is_current = (f[2].strip() == "*");
                b.upstream = f[3];
                parse_track(f[4], out b.ahead, out b.behind);
                b.tip = f[5];
                list.add(b);
            }
            return list;
        }

        private void parse_track(string track, out int ahead, out int behind) {
            ahead = 0; behind = 0;
            if (track == "") return;
            var m = /ahead (\d+)/;
            MatchInfo mi;
            try {
                if (m.match(track, 0, out mi)) ahead = int.parse(mi.fetch(1));
            } catch (Error e) {}
            try {
                var m2 = /behind (\d+)/;
                if (m2.match(track, 0, out mi)) behind = int.parse(mi.fetch(1));
            } catch (Error e) {}
        }

        // ── Status ───────────────────────────────────────────────────────────
        public async StatusReport status() {
            var rep = new StatusReport();
            // NOTE: do NOT use `-z` here. Its output is NUL-separated, and
            // communicate_utf8_async returns a C string that truncates at the
            // first NUL, so only the branch header survived and every file
            // entry was silently dropped (Working Changes appeared empty).
            // Parse the newline form instead; core.quotePath=false keeps
            // non-ASCII paths unescaped.
            var r = yield run({ "git", "-c", "core.quotePath=false",
                                "status", "--porcelain=v1", "--branch" });
            if (!r.ok) return rep;
            foreach (var line in r.stdout_text.split("\n")) {
                if (line == "") continue;
                if (line.has_prefix("## ")) {
                    parse_branch_header(line.substring(3), rep);
                    continue;
                }
                if (line.length < 4) continue;   // "XY P"
                char x = line[0];
                char y = line[1];
                string p = line.substring(3);
                string orig = "";
                if (x == 'R' || x == 'C') {
                    int arrow = p.index_of(" -> ");
                    if (arrow >= 0) { orig = p.substring(0, arrow); p = p.substring(arrow + 4); }
                }
                classify(rep, x, y, p, orig);
            }
            return rep;
        }

        private void parse_branch_header(string h, StatusReport rep) {
            // "main...origin/main [ahead 1, behind 2]" or "No commits yet on main"
            string branch = h;
            int sp = h.index_of(" ");
            string head = (sp > 0) ? h.substring(0, sp) : h;
            int dots = head.index_of("...");
            rep.branch = (dots > 0) ? head.substring(0, dots) : head;
            parse_track(h, out rep.ahead, out rep.behind);
        }

        private void classify(StatusReport rep, char x, char y, string p, string orig) {
            if (x == '?' && y == '?') {
                var fc = mk(p, FileState.UNTRACKED, false); rep.untracked.add(fc); return;
            }
            if (x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')) {
                var fc = mk(p, FileState.CONFLICTED, false); fc.conflicted = true;
                rep.conflicts.add(fc); return;
            }
            // Staged side (index) - X column
            if (x != ' ' && x != '?') {
                var fc = mk(p, state_of(x), true); fc.orig_path = orig;
                rep.staged.add(fc);
            }
            // Unstaged side (work tree) - Y column
            if (y != ' ' && y != '?') {
                var fc = mk(p, state_of(y), false); fc.orig_path = orig;
                rep.unstaged.add(fc);
            }
        }

        private FileChange mk(string p, FileState st, bool staged) {
            var fc = new FileChange();
            fc.path = p; fc.state = st; fc.staged = staged;
            return fc;
        }

        private FileState state_of(char c) {
            switch (c) {
                case 'M': return FileState.MODIFIED;
                case 'A': return FileState.ADDED;
                case 'D': return FileState.DELETED;
                case 'R': return FileState.RENAMED;
                case 'T': return FileState.TYPECHANGE;
                default:  return FileState.MODIFIED;
            }
        }

        // ── Diffs ──────────────────────────────────────────────────────────
        public async string diff_working(string file, bool staged) {
            string[] argv = staged
                ? new string[] { "git", "diff", "--cached", "--", file }
                : new string[] { "git", "diff", "--", file };
            var r = yield run(argv);
            return r.stdout_text;
        }

        public async string diff_untracked(string file) {
            // Show new-file content as an all-add diff.
            var r = yield run({ "git", "diff", "--no-index", "--", "/dev/null", file });
            return r.stdout_text;
        }

        public async string diff_commit(string hash, string? file = null) {
            string[] argv = (file != null)
                ? new string[] { "git", "show", hash, "--", file }
                : new string[] { "git", "show", hash };
            var r = yield run(argv);
            return r.stdout_text;
        }

        public async string[] commit_files(string hash) {
            var r = yield run({ "git", "show", "--name-only", "--pretty=format:", hash });
            var outl = new Gee.ArrayList<string>();
            foreach (var l in r.stdout_text.split("\n"))
                if (l.strip() != "") outl.add(l.strip());
            return outl.to_array();
        }

        // ── Mutating ops ─────────────────────────────────────────────────────
        public async GitResult stage(string file) {
            var r = yield run({ "git", "add", "--", file });
            changed(); return r;
        }
        public async GitResult unstage(string file) {
            var r = yield run({ "git", "reset", "-q", "HEAD", "--", file });
            changed(); return r;
        }
        public async GitResult stage_all() {
            var r = yield run({ "git", "add", "-A" });
            changed(); return r;
        }
        public async GitResult discard(string file) {
            var r = yield run({ "git", "checkout", "--", file });
            changed(); return r;
        }
        public async GitResult commit(string message) {
            var r = yield run({ "git", "commit", "-m", message });
            changed(); return r;
        }
        public async GitResult checkout(string branch) {
            var r = yield run({ "git", "checkout", branch });
            changed(); return r;
        }
        public async GitResult create_branch(string name, bool checkout_it) {
            var r = checkout_it
                ? yield run({ "git", "checkout", "-b", name })
                : yield run({ "git", "branch", name });
            changed(); return r;
        }
        public async GitResult fetch() {
            var r = yield run({ "git", "fetch", "--all", "--prune" });
            changed(); return r;
        }
        public async GitResult pull() {
            var r = yield run({ "git", "pull", "--ff-only" });
            changed(); return r;
        }
        public async GitResult push() {
            var r = yield run({ "git", "push" });
            changed(); return r;
        }
        public async GitResult stage_conflict_resolved(string file) {
            var r = yield run({ "git", "add", "--", file });
            changed(); return r;
        }
    }
}
