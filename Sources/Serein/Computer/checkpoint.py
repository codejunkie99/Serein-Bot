"""Guest-only home checkpoint worker. Host supplies the operation and the app-bundled source.
Archive paths are data. Extraction takes place in a private staging directory before the
bounded top-level rename transaction. No archive member is extracted through a link.
"""
import os
import hashlib
import ctypes
import fcntl
import json
import pwd
import shutil
import stat
import sys
import tarfile
import tempfile

SKIP = {".Xauthority"}
TRANSACTION = ".serein-checkpoint-transaction-v1"
MAX_MEMBERS = 500_000
MAX_BYTES = 64 * 1024**3


def components(name):
    while name.startswith("./"):
        name = name[2:]
    if name in ("", "."):
        return ()
    parts = name.split("/")
    if any(p in ("", ".", "..") for p in parts) or len(parts) > 100 or len(name.encode()) > 4096:
        raise ValueError("invalid checkpoint path")
    return tuple(parts)


def owners():
    accounts = [pwd.getpwnam("serein")]
    try:
        accounts.append(pwd.getpwnam("shell"))
    except KeyError:
        pass
    return {p.pw_uid: p.pw_gid for p in accounts}


def digest_member(digest, item):
    data = json.dumps([item.name, item.type.decode("ascii"), item.uid, item.gid,
                       item.mode, item.mtime, item.size, item.linkname], ensure_ascii=True).encode()
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)


class DigestReader:
    def __init__(self, file, digest):
        self.file, self.digest = file, digest

    def read(self, size):
        data = self.file.read(size)
        self.digest.update(data)
        return data


def export(home, stream, users):
    count = size = 0
    inodes = {}
    digest = hashlib.sha256()
    with tarfile.open(fileobj=stream, mode="w|", dereference=False, pax_headers={"Serein.version": "1"}) as archive:
        def walk(fd, prefix):
            nonlocal count, size
            for name in sorted(os.listdir(fd)):
                parts = prefix + (name,)
                if parts[0] in SKIP:
                    continue
                path = "/".join(parts)
                components(path)
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if info.st_uid not in users or info.st_gid not in users.values():
                    raise ValueError("unexpected checkpoint file owner")
                count += 1
                if count > MAX_MEMBERS:
                    raise ValueError("checkpoint contains too many entries")
                item = tarfile.TarInfo(path)
                item.uid, item.gid = info.st_uid, info.st_gid
                item.mode, item.mtime = info.st_mode & 0o777, int(info.st_mtime)
                if stat.S_ISLNK(info.st_mode):
                    item.type, item.linkname = tarfile.SYMTYPE, os.readlink(name, dir_fd=fd)
                    digest_member(digest, item)
                    archive.addfile(item)
                    continue
                if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                    raise ValueError("checkpoint contains an unsupported file type")
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if stat.S_ISDIR(info.st_mode):
                    flags |= os.O_DIRECTORY
                opened = os.open(name, flags, dir_fd=fd)
                try:
                    current = os.fstat(opened)
                    if (current.st_dev, current.st_ino, current.st_mode, current.st_uid, current.st_gid) != (
                            info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid):
                        raise ValueError("a checkpoint entry changed during save")
                    if stat.S_ISDIR(current.st_mode):
                        item.type = tarfile.DIRTYPE
                        digest_member(digest, item)
                        archive.addfile(item)
                        walk(opened, parts)
                    else:
                        inode = (current.st_dev, current.st_ino)
                        if current.st_nlink > 1 and inode in inodes:
                            item.type, item.linkname = tarfile.LNKTYPE, inodes[inode]
                            digest_member(digest, item)
                            archive.addfile(item)
                            continue
                        if current.st_nlink > 1:
                            inodes[inode] = path
                        item.size = current.st_size
                        size += item.size
                        if size > MAX_BYTES:
                            raise ValueError("checkpoint exceeds the size limit")
                        with os.fdopen(os.dup(opened), "rb") as data:
                            digest_member(digest, item)
                            archive.addfile(item, DigestReader(data, digest))
                    after = os.fstat(opened)
                    if (after.st_mtime_ns, after.st_ctime_ns) != (current.st_mtime_ns, current.st_ctime_ns):
                        raise ValueError("a checkpoint entry changed during save")
                finally:
                    os.close(opened)
        root = os.open(home, os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            before = os.fstat(root)
            walk(root, ())
            after = os.fstat(root)
            if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError("the home changed during save")
        finally:
            os.close(root)
        end = tarfile.TarInfo(".")
        end.type = tarfile.DIRTYPE
        end.pax_headers = {"Serein.sha256": digest.hexdigest()}
        archive.addfile(end)


class ArchiveReader:
    def __init__(self, stream):
        self.stream = stream
        self.length = 0
        self.tail = b""

    def read(self, size):
        data = self.stream.read(size)
        self.length += len(data)
        self.tail = (self.tail + data)[-1024:]
        return data


def unpack(stream, stage, users, require_seal=False):
    """Create only ordinary files, links and directories below the root-owned stage.
    Delay all ownership changes until extraction has finished, with the stage still private.
    """
    seen = {}
    metadata = []
    total = 0
    digest = hashlib.sha256()
    sealed, finished, saw_member = False, False, False
    reader = ArchiveReader(stream)
    with tarfile.open(fileobj=reader, mode="r|") as archive:
        for record in archive:
            saw_member = True
            if finished:
                raise ValueError("unexpected data after the checkpoint manifest")
            version = archive.pax_headers.get("Serein.version")
            if version not in (None, "1"):
                raise ValueError("unsupported checkpoint version")
            sealed = version == "1"
            if sealed and "Serein.sha256" in record.pax_headers:
                if record.name != "." or record.pax_headers["Serein.sha256"] != digest.hexdigest():
                    raise ValueError("checkpoint digest mismatch")
                finished = True
                continue
            if sealed:
                digest_member(digest, record)
            parts = components(record.name.rstrip("/") if record.isdir() else record.name)
            if not parts or parts[0] in SKIP:
                continue
            if parts in seen or len(seen) >= MAX_MEMBERS:
                raise ValueError("duplicate or excessive checkpoint entries")
            if parts[:-1] and seen.get(parts[:-1]) != "dir":
                raise ValueError("missing directory or unsafe checkpoint parent")
            if record.uid not in users or record.gid not in users.values() or record.size < 0:
                raise ValueError("unsupported checkpoint ownership or size")
            path = os.path.join(stage, *parts) if stage is not None else None
            if record.isdir():
                if path is not None:
                    os.mkdir(path, 0o700)
                kind = "dir"
            elif record.isreg():
                total += record.size
                if total > MAX_BYTES:
                    raise ValueError("checkpoint exceeds the size limit")
                with archive.extractfile(record) as src:
                    contents = DigestReader(src, digest) if sealed else src
                    if path is None:
                        while contents.read(64 * 1024):
                            pass
                    else:
                        with open(path, "xb") as dst:
                            shutil.copyfileobj(contents, dst)
                            dst.flush()
                            os.fsync(dst.fileno())
                kind = "file"
            elif record.islnk():
                target = components(record.linkname)
                if seen.get(target) != "file":
                    raise ValueError("invalid checkpoint hard link")
                if path is not None:
                    os.link(os.path.join(stage, *target), path, follow_symlinks=False)
                kind = "file"
            elif record.issym():
                if path is not None:
                    os.symlink(record.linkname, path)
                kind = "link"
            else:
                raise ValueError("unsupported checkpoint entry")
            seen[parts] = kind
            if path is not None:
                metadata.append((path, record, kind))
        end_offset = archive.offset
    while reader.read(64 * 1024):
        pass
    if reader.length < end_offset + 1024 or reader.length % 512 or reader.tail != bytes(1024):
        raise ValueError("checkpoint is truncated")
    if not saw_member or ((sealed or require_seal) and not finished):
        raise ValueError("checkpoint is incomplete")
    if ("work",) in seen and seen[("work",)] != "dir":
        raise ValueError("checkpoint work folder is invalid")
    for path, rec, kind in reversed(metadata):
        os.chown(path, rec.uid, rec.gid, follow_symlinks=False)
        if kind != "link":
            os.chmod(path, rec.mode & 0o777)
        os.utime(path, (rec.mtime, rec.mtime), follow_symlinks=False)
        if kind == "dir":
            sync_dir(path)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def stage_home(stream, stage, users):
    os.mkdir(stage, 0o700)
    unpack(stream, stage, users)
    work = os.path.join(stage, "work")
    if len(users) > 1:
        if not os.path.isdir(work):
            os.mkdir(work)
        desktop = pwd.getpwnam("serein")
        os.chown(work, desktop.pw_uid, desktop.pw_gid)
        os.chmod(work, 0o2770)
        sync_dir(work)
    sync_dir(stage)


def rollback_volume(home, force=False):
    """Recover before the desktop restarts. Never remove a guest-created name collision."""
    journal = os.path.join(home, TRANSACTION)
    if not os.path.lexists(journal):
        return
    info = os.lstat(journal)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("checkpoint recovery workspace is occupied")
    intent = os.path.join(journal, "intent")
    done = os.path.join(journal, "done")
    if force and os.path.exists(done):
        os.unlink(done)
    if os.path.exists(intent) and not os.path.exists(done):
        with open(intent) as f:
            old_names, new_names = json.load(f)
        previous = os.path.join(journal, "previous")
        stage = os.path.join(journal, "new")
        for name in new_names:
            current = os.path.join(home, name)
            staged = os.path.join(stage, name)
            if not os.path.lexists(staged) and os.path.lexists(current):
                os.rename(current, staged)
        for name in old_names:
            backup = os.path.join(previous, name)
            if os.path.lexists(backup):
                os.rename(backup, os.path.join(home, name))
        sync_dir(home)
        sync_dir(previous)
        sync_dir(stage)
    # Atomic rename marks a finished rollback before cleanup can itself be interrupted.
    if os.path.exists(intent):
        os.rename(intent, os.path.join(journal, "retired"))
        sync_dir(journal)
    shutil.rmtree(journal)
    sync_dir(home)


def restore_volume(home, stream, users):
    rollback_volume(home)
    journal = os.path.join(home, TRANSACTION)
    os.mkdir(journal, 0o700)
    sync_dir(home)
    try:
        stage = os.path.join(journal, "new")
        previous = os.path.join(journal, "previous")
        os.mkdir(previous, 0o700)
        stage_home(stream, stage, users)
        old_names = [name for name in os.listdir(home) if name not in SKIP and name != TRANSACTION]
        new_names = os.listdir(stage)
        if TRANSACTION in new_names:
            raise ValueError("checkpoint includes reserved recovery workspace")
        with open(os.path.join(journal, "pending"), "x") as f:
            json.dump([old_names, new_names], f)
            f.flush()
            os.fsync(f.fileno())
        os.rename(os.path.join(journal, "pending"), os.path.join(journal, "intent"))
        sync_dir(journal)
        for name in old_names:
            os.rename(os.path.join(home, name), os.path.join(previous, name))
        sync_dir(previous)
        sync_dir(home)
        for name in new_names:
            os.rename(os.path.join(stage, name), os.path.join(home, name))
        sync_dir(stage)
        sync_dir(home)
        with open(os.path.join(journal, "committing"), "x") as f:
            os.fsync(f.fileno())
        os.rename(os.path.join(journal, "committing"), os.path.join(journal, "done"))
        sync_dir(journal)
    except BaseException:
        rollback_volume(home, force=True)
        raise
    # The restored home is durable. If cleanup fails, the next start retries it.
    try:
        rollback_volume(home)
    except OSError:
        pass


def exchange(left, right):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameat2(-100, os.fsencode(left), -100, os.fsencode(right), 2):
        raise OSError(ctypes.get_errno(), "cannot exchange checkpoint home")


def restore(home, stream, users, check_only):
    if check_only:
        # Validate all entries and bytes without touching the guest filesystem.
        return unpack(stream, None, users, require_seal=True)
    docker = home == "/checkpoint"
    if docker:
        return restore_volume(home, stream, users)
    parent = os.path.dirname(home)
    if os.stat(parent).st_dev != os.stat(home).st_dev:
        raise ValueError("safe checkpoint staging is unavailable on this volume")
    workspace = tempfile.mkdtemp(prefix=".serein-checkpoint-", dir=parent)
    keep_backup = False
    try:
        stage = os.path.join(workspace, "new")
        stage_home(stream, stage, users)
        desktop = pwd.getpwnam("serein")
        os.chown(stage, desktop.pw_uid, desktop.pw_gid)
        os.chmod(stage, 0o710)
        exchange(stage, home)
        keep_backup = True
        try:
            sync_dir(parent)
            sync_dir(workspace)
        except BaseException:
            # stage now holds the original. If the inverse exchange itself fails, retain both
            # trees on disk. The Mac also keeps the source sandbox until startup succeeds.
            exchange(stage, home)
            sync_dir(parent)
            sync_dir(workspace)
            keep_backup = False
            raise
        keep_backup = False
    finally:
        if not keep_backup:
            shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    operation, home = sys.argv[1:]
    # Two app launches may overlap after an interruption. The volume itself is the lock:
    # a worker must have exited (or finished) before the next recovery can access its journal.
    if home == "/checkpoint" and operation != "check":
        lock_fd = os.open(home, os.O_DIRECTORY | os.O_NOFOLLOW)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
    if operation == "save":
        export(home, sys.stdout.buffer, owners())
    elif operation == "recover" and home == "/checkpoint":
        rollback_volume(home)
    elif operation in ("check", "restore"):
        restore(home, sys.stdin.buffer, owners(), operation == "check")
    else:
        sys.exit("unsupported checkpoint operation")
