"""Safe, Navigator-local library maintenance.

This module deliberately knows nothing about CODEX_HOME or the app-server.  A
backup is a portable archive of Navigator's cache only.  In particular, it
never follows a symlink while collecting or restoring files.
"""
import base64
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import stat
import tempfile
import uuid
import zipfile


FORMAT = 1
MAX_FILES = 100_000
MAX_UNCOMPRESSED = 8 * 1024 * 1024 * 1024
SQLITE_NAMES = {'navigator.sqlite', 'navigator.sqlite-wal', 'navigator.sqlite-shm'}
REQUIRED_TABLES = {'metadata', 'turns', 'hydration', 'overrides', 'preferences', 'observations', 'turn_versions'}
JSON_PAYLOAD_TABLES = ('metadata', 'turns', 'preferences', 'observations')


def _cache_root(cache):
    """Return a lexical cache path without following a cache-root symlink."""
    root = Path(cache).absolute()
    try:
        if root.is_symlink():
            raise ValueError('Navigator cache must not be a symlink.')
    except OSError as exc:
        raise ValueError('Navigator cache is unavailable.') from exc
    return root


def _valid_json_payloads(connection):
    """Reject a structurally complete database whose saved records cannot load."""
    try:
        for table in JSON_PAYLOAD_TABLES:
            for (raw,) in connection.execute('SELECT data FROM ' + table):
                if not isinstance(raw,str) or not isinstance(json.loads(raw),dict):
                    return False
    except (sqlite3.Error, TypeError, ValueError):
        return False
    return True


def _safe_preferences(value):
    """Keep only Navigator UI preferences; never package arbitrary defaults."""
    if not isinstance(value, dict):
        return {}
    result = {}
    for key, item in value.items():
        if (not isinstance(key, str) or not key.startswith('navigator.') or
                key == 'navigator.previewAccess' or
                any(word in key.lower() for word in ('token', 'secret', 'password', 'auth'))):
            continue
        if not _safe_preference_value(item):
            continue
        try:
            encoded = json.dumps(item, ensure_ascii=False)
        except (TypeError, ValueError):
            continue
        if len(encoded.encode()) <= 64 * 1024:
            result[key] = item
    return result


def _safe_preference_value(value):
    """Reject secret-shaped nested fields and validate exported Data wrappers."""
    if isinstance(value, dict):
        if set(value) == {'__navigatorData'}:
            encoded=value['__navigatorData']
            if not isinstance(encoded,str) or len(encoded) > 90_000:
                return False
            try:
                return len(base64.b64decode(encoded,validate=True)) <= 64 * 1024
            except (ValueError, TypeError):
                return False
        return all(isinstance(key,str) and not any(word in key.lower() for word in ('token','secret','password','auth'))
                   and _safe_preference_value(item) for key,item in value.items())
    if isinstance(value, list):
        return all(_safe_preference_value(item) for item in value)
    return value is None or isinstance(value,(str,int,float,bool))


def _require_outside(root, path):
    try:
        path.relative_to(root)
    except ValueError:
        return
    raise ValueError('Backup path must not be inside the Navigator cache.')


def _regular_files(root):
    """Yield relative paths of regular files without traversing symlink dirs."""
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(base) / name).is_symlink()]
        for name in files:
            path = Path(base) / name
            try:
                mode = path.lstat().st_mode
            except OSError:
                continue
            if stat.S_ISREG(mode):
                yield path.relative_to(root), path


def _copy_fd_to_zip(archive, name, path):
    flags = os.O_RDONLY
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError('Cannot safely read cache file: ' + path.name) from exc
    try:
        with os.fdopen(descriptor, 'rb') as source, archive.open(name, 'w') as target:
            shutil.copyfileobj(source, target, 1024 * 1024)
    except Exception:
        # fdopen owns descriptor after successful construction.
        raise


def _sqlite_snapshot(connection, destination):
    target = sqlite3.connect(str(destination))
    try:
        connection.backup(target)
        target.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    finally:
        target.close()


def backup(cache, connection, destination, ui_preferences=None):
    """Write an atomic ZIP archive and return its non-sensitive manifest."""
    root = _cache_root(cache)
    output = Path(destination)
    if not output.is_absolute() or output.name in ('', '.', '..'):
        raise ValueError('Choose an absolute backup file path.')
    output = output.resolve()
    if not output.parent.is_dir():
        raise ValueError('Choose a backup folder that exists.')
    _require_outside(root, output)
    temporary = output.with_name('.' + output.name + '.tmp-' + uuid.uuid4().hex)
    with tempfile.TemporaryDirectory(prefix='navigator-backup-') as scratch_name:
        snapshot = Path(scratch_name) / 'navigator.sqlite'
        _sqlite_snapshot(connection, snapshot)
        files = []
        try:
            with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
                for relative, path in _regular_files(root):
                    if relative.as_posix() in SQLITE_NAMES:
                        continue
                    name = 'cache/' + relative.as_posix()
                    _copy_fd_to_zip(archive, name, path)
                    files.append(name)
                _copy_fd_to_zip(archive, 'cache/navigator.sqlite', snapshot)
                manifest = {'format': FORMAT, 'files': len(files) + 1, 'cacheRoot':str(root),
                            'uiPreferences': _safe_preferences(ui_preferences)}
                archive.writestr('manifest.json', json.dumps(manifest, sort_keys=True))
            os.replace(temporary, output)
        except Exception:
            try:
                temporary.unlink()
            except OSError:
                pass
            raise
    return {'path': str(output), 'files': len(files) + 1,
            'uiPreferences': _safe_preferences(ui_preferences)}


def _archive_name(name):
    path = PurePosixPath(name)
    if (path.is_absolute() or not name or '\\' in name or '..' in path.parts or
            path.parts[0] not in ('cache', 'manifest.json')):
        raise ValueError('Backup contains an unsafe path.')
    if path.parts[0] == 'manifest.json' and len(path.parts) != 1:
        raise ValueError('Backup manifest path is invalid.')
    return path


def _validate_archive(source):
    try:
        archive = zipfile.ZipFile(source)
    except (OSError, zipfile.BadZipFile) as exc:
        raise ValueError('Choose a valid Navigator backup archive.') from exc
    try:
        names = set()
        total = 0
        manifest = None
        for info in archive.infolist():
            path = _archive_name(info.filename)
            if info.filename in names or info.is_dir():
                if info.is_dir():
                    continue
                raise ValueError('Backup contains duplicate paths.')
            names.add(info.filename)
            # External attributes encode Unix file type. Symlinks must never
            # become a route out of the restore directory.
            if stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError('Backup contains unsupported symlinks.')
            total += info.file_size
            if len(names) > MAX_FILES or total > MAX_UNCOMPRESSED:
                raise ValueError('Backup is too large to restore safely.')
            if path.name == 'manifest.json':
                try:
                    manifest = json.loads(archive.read(info).decode('utf-8'))
                except (ValueError, UnicodeError) as exc:
                    raise ValueError('Backup manifest is invalid.') from exc
        if not isinstance(manifest, dict) or manifest.get('format') != FORMAT:
            raise ValueError('Backup format is not supported.')
        if 'cache/navigator.sqlite' not in names:
            raise ValueError('Backup does not contain its history database.')
        source_root=manifest.get('cacheRoot')
        if not isinstance(source_root,str) or not Path(source_root).is_absolute():
            source_root=None
        return archive, _safe_preferences(manifest.get('uiPreferences')), source_root
    except Exception:
        archive.close()
        raise


def _extract_regular(archive, info, destination):
    relative = _archive_name(info.filename)
    if relative.parts[0] != 'cache' or info.is_dir():
        return
    target = destination.joinpath(*relative.parts[1:])
    if _has_symlink_ancestor(destination, target):
        raise ValueError('Backup would write through a retained symlink.')
    target.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(info, 'r') as source, open(target, 'xb') as output:
        shutil.copyfileobj(source, output, 1024 * 1024)


def _has_symlink_ancestor(root, target):
    try:
        relative=target.relative_to(root)
    except ValueError:
        return True
    current=root
    for part in relative.parts[:-1]:
        current=current / part
        if current.is_symlink():
            return True
    return False


def _copy_current(cache, staged):
    for relative, source in _regular_files(cache):
        target = staged / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # Files are copied, never linked, so a later restore cannot follow a
        # user-created link out of the cache.
        shutil.copyfile(source, target, follow_symlinks=False)
    # Projectless task directories are user working folders, not replaceable
    # Navigator cache. Keep their layout byte-for-byte, including symlinks,
    # without resolving or traversing those links.
    roots = [cache / 'tasks']
    composers = cache / 'composers'
    if composers.is_dir() and not composers.is_symlink():
        for child in composers.iterdir():
            if child.is_dir() and not child.is_symlink():
                roots.append(child / 'tasks')
    for source in roots:
        relative = source.relative_to(cache)
        target = staged / relative
        if source.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() and not target.is_symlink():
                target.symlink_to(os.readlink(source))
        elif source.is_dir():
            shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)


def _rebase_cached_logos(database, source_root, staged_root, final_root):
    """A portable restore must not leave cache-owned logos pointing to old roots."""
    if not source_root:
        return
    try:
        old_root=Path(source_root)
        connection=sqlite3.connect(str(database))
        try:
            rows=connection.execute('SELECT id,data FROM preferences').fetchall()
            with connection:
                for key, raw in rows:
                    try: preference=json.loads(raw)
                    except ValueError: continue
                    logo=preference.get('logo') if isinstance(preference,dict) else None
                    if not isinstance(logo,str): continue
                    try: relative=Path(logo).resolve().relative_to(old_root.resolve())
                    except ValueError: continue
                    staged_logo=staged_root / relative
                    if staged_logo.is_file() and not staged_logo.is_symlink():
                        preference['logo']=str(final_root.resolve() / relative)
                        connection.execute('UPDATE preferences SET data=? WHERE id=?',(json.dumps(preference),key))
        finally:
            connection.close()
    except (OSError, sqlite3.Error):
        # A database integrity failure is reported by the validation that follows.
        return


def _projectless_relative(path, source_root):
    """Return a lexical relative cache task path, never resolving external links."""
    if not source_root or not isinstance(path,str):
        return None
    try:
        relative=Path(path).relative_to(Path(source_root))
    except ValueError:
        return None
    return relative if _is_projectless_source(relative) else None


def _rebase_composer_attachments(staged_root, source_root, final_root):
    """Only imported cache attachments move on restore; source references do not."""
    if not source_root: return
    original=Path(source_root) / 'attachments'
    def visit(value):
        if isinstance(value, dict):
            for attachment in value.get('attachments') or []:
                if not isinstance(attachment,dict) or attachment.get('kind') in ('url','remoteImage'): continue
                try: relative=Path(attachment['path']).relative_to(original)
                except (KeyError,ValueError,TypeError): continue
                if '..' not in relative.parts:
                    attachment['path']=str(final_root / 'attachments' / relative)
            for child in value.values(): visit(child)
        elif isinstance(value, list):
            for child in value: visit(child)
    for _, path in _regular_files(staged_root):
        if path.name not in ('composer-editors.json','composer.json'): continue
        try: value=json.loads(path.read_text())
        except (OSError,ValueError): continue
        before=json.dumps(value,ensure_ascii=False)
        visit(value)
        after=json.dumps(value,ensure_ascii=False)
        if after != before: path.write_text(after)


def _rebase_composer_cwds(staged_root, source_root, final_root):
    """Move only cache-owned projectless CWDs; external CWDs stay byte-for-byte."""
    if not source_root:
        return
    for relative, path in _regular_files(staged_root):
        if path.name != 'composer.json':
            continue
        try:
            value=json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(value,dict):
            continue
        task_relative=_projectless_relative(value.get('cwd'),source_root)
        if task_relative is None:
            continue
        value['cwd']=str(final_root.resolve() / task_relative)
        try:
            path.write_text(json.dumps(value,ensure_ascii=False))
        except OSError:
            pass


def _rebase_launch_preferences(preferences, source_root, final_root):
    """Rebase only encoded LaunchPlan paths that target projectless cache work."""
    if not source_root:
        return preferences
    for key, value in preferences.items():
        if not key.startswith('navigator.launchPlan.') or not isinstance(value,dict) or set(value) != {'__navigatorData'}:
            continue
        try:
            plan=json.loads(base64.b64decode(value['__navigatorData'],validate=True).decode('utf-8'))
            relative=_projectless_relative(plan.get('path'),source_root)
            if relative is None:
                continue
            plan['path']=str(final_root.resolve() / relative)
            value['__navigatorData']=base64.b64encode(json.dumps(plan,separators=(',',':')).encode()).decode()
        except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
            continue
    return preferences


def _is_projectless_source(relative):
    parts = relative.parts
    return (len(parts) >= 1 and parts[0] == 'tasks') or (len(parts) >= 4 and parts[0] == 'composers' and 'tasks' in parts[2:])


def restore(cache, source):
    """Validate, stage and atomically replace cache data.

    Existing projectless task files are retained when absent from a backup and
    are never overwritten by an older backup. This keeps user working files out
    of cache repair semantics.
    """
    root = _cache_root(cache)
    archive_path = Path(source)
    if not archive_path.is_absolute() or archive_path.is_symlink() or not archive_path.is_file():
        raise ValueError('Choose an existing backup archive.')
    archive_path = archive_path.resolve()
    _require_outside(root, archive_path)
    archive, preferences, source_root = _validate_archive(archive_path)
    parent = root.parent
    staged = parent / ('.' + root.name + '.restore-' + uuid.uuid4().hex)
    previous = parent / ('.' + root.name + '.previous-' + uuid.uuid4().hex)
    try:
        staged.mkdir(mode=0o700)
        _copy_current(root, staged)
        for name in SQLITE_NAMES:
            try:
                (staged / name).unlink()
            except FileNotFoundError:
                pass
        for info in archive.infolist():
            relative = _archive_name(info.filename)
            if relative.parts[0] != 'cache' or info.is_dir():
                continue
            destination = staged.joinpath(*relative.parts[1:])
            projectless=_is_projectless_source(relative.relative_to('cache'))
            if projectless and (destination.exists() or destination.is_symlink() or _has_symlink_ancestor(staged,destination)):
                continue
            if _has_symlink_ancestor(staged,destination):
                raise ValueError('Backup would write through a retained symlink.')
            if destination.exists() or destination.is_symlink():
                destination.unlink()
            _extract_regular(archive, info, staged)
        db = staged / 'navigator.sqlite'
        _rebase_cached_logos(db, source_root, staged, root)
        _rebase_composer_cwds(staged, source_root, root)
        _rebase_composer_attachments(staged, source_root, root)
        verified = sqlite3.connect(str(db))
        try:
            try:
                integrity = verified.execute('PRAGMA integrity_check').fetchone()[0]
                tables={row[0] for row in verified.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            except sqlite3.Error as exc:
                raise ValueError('Backup database did not pass validation.') from exc
            if integrity != 'ok' or not REQUIRED_TABLES.issubset(tables) or not _valid_json_payloads(verified):
                raise ValueError('Backup database did not pass validation.')
        finally:
            verified.close()
        os.replace(root, previous)
        try:
            os.replace(staged, root)
        except Exception:
            os.replace(previous, root)
            raise
        # Keep the previous directory only long enough to establish that the
        # replacement succeeded. It contains only Navigator cache data.
        shutil.rmtree(previous)
        return {'uiPreferences': _rebase_launch_preferences(preferences,source_root,root)}
    except Exception:
        if staged.exists():
            shutil.rmtree(staged, ignore_errors=True)
        raise
    finally:
        archive.close()
