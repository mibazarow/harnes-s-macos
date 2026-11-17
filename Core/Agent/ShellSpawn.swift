import Darwin
import Foundation

/// Starts `/bin/zsh -lc` in its own process group with output redirected to files.
///
/// Shared by the synchronous `bash` tool and the background process registry: both need
/// a group leader so `kill(-pid, …)` reaches build tools and servers, and both redirect
/// to files so a chatty command cannot block on a full pipe.
enum ShellSpawn {
    static func spawn(
        command: String,
        cwd: URL,
        stdoutPath: String,
        stderrPath: String,
        append: Bool
    ) throws -> pid_t {
        // The imported posix_spawn types are optional opaque pointers on this SDK: the
        // _init call allocates and fills them.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // /dev/null on stdin: an interactive prompt would otherwise wait for input that
        // never comes and burn the whole timeout.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC)
        posix_spawn_file_actions_addopen(&actions, 1, stdoutPath, flags, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, stderrPath, flags, 0o600)
        posix_spawn_file_actions_addchdir(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        // pgroup 0 means "use the child's own pid": the child becomes the group leader.
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/zsh"), strdup("-lc"), strdup(command), nil
        ]
        defer { argv.forEach { pointer in if let pointer { free(pointer) } } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, environ)
        guard spawned == 0 else {
            throw NSError(domain: "Harness", code: Int(spawned), userInfo: [
                NSLocalizedDescriptionKey: "Не удалось запустить команду (errno \(spawned))."
            ])
        }
        return pid
    }
}
