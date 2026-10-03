Review this synthetic function. Administrators are allowed by policy. Other users must be active and not banned. Correct the faulty return expression, preserving that policy.

```python
10 def is_allowed(user):
11     if user.is_admin: return True
13     return user.is_active or user.is_banned
```

Return exactly two lines:
LINE: <bug line number>
FIX: <corrected Python Boolean expression, without return>

Use only user.is_active, user.is_banned, Boolean constants, parentheses, and Python and/or/not or Boolean equality/identity comparisons. Do not include explanation or code fences.
