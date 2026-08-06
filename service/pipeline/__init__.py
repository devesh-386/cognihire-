"""Pipeline — orchestration and persistence.

Sequences the `deterministic/` and `ai/` stages and writes the result to the
candidate's AI profile. Contains no extraction logic and no prompts of its
own: this package decides *order and durability*, never *meaning*.
"""

from . import profile_builder, supabase_store

__all__ = ["profile_builder", "supabase_store"]
