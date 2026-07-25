"""smeggdrop: evaluates Tcl in chat rooms, with persistent versioned state."""

from smeggdrop.engine import Engine, EvalRequest, EvalResult, Limits
from smeggdrop.state import FileStateStore

__all__ = ["Engine", "EvalRequest", "EvalResult", "Limits", "FileStateStore"]
