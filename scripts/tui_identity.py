"""Install identity, sampled outside rendering; never the working project's HEAD."""
import subprocess
from pathlib import Path


def identity(root):
    root = Path(root).resolve()
    result = {'commit': None, 'dirty': None, 'label': 'source unavailable'}
    try:
        def git(*args):
            return subprocess.run(['git', '-C', str(root), *args], capture_output=True,
                                  text=True, timeout=2, check=True).stdout.strip()
        if Path(git('rev-parse', '--show-toplevel')).resolve() != root:
            return result
        sha = git('rev-parse', 'HEAD')
        # Tracked edits and unignored source additions count; ignored build/session
        # artifacts follow this installation's gitignore, never project files.
        dirty = bool(git('status', '--porcelain', '--untracked-files=normal'))
        result.update(commit=sha, dirty=dirty, label=sha[:8]+(' +dirty' if dirty else ''))
    except (OSError, subprocess.SubprocessError):
        pass
    return result
