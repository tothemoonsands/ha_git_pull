#!/usr/bin/env python3
"""Conservatively compare automation YAML without executing tags or templates."""
import os
import stat
import subprocess
import sys

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode


STR = 'tag:yaml.org,2002:str'
SCALARS = {STR, *('tag:yaml.org,2002:' + kind for kind in
                  ('null', 'bool', 'int', 'float', 'timestamp'))}
ALIASES = {'trigger': 'triggers', 'condition': 'conditions', 'action': 'actions'}


def canonical(data):
    if len(data) > 4 * 1024 * 1024:
        raise ValueError('Automation file too large')
    # Refuse aliases, merge keys and custom tags instead of guessing HA semantics.
    if any(isinstance(token, yaml.tokens.AliasToken) for token in yaml.scan(data)):
        raise ValueError('YAML aliases require review')
    root = yaml.compose(data, Loader=yaml.SafeLoader)
    if not isinstance(root, SequenceNode):
        raise ValueError('Expected an automation list')
    remaining = 100000

    def visit(node, context='', depth=0):
        nonlocal remaining
        remaining -= 1
        if remaining < 0 or depth > 100:
            raise ValueError('YAML complexity limit exceeded')
        if isinstance(node, ScalarNode) and node.tag in SCALARS:
            # Keep scalar types and exact decoded strings (including Jinja whitespace).
            return (node.tag, node.value)
        if isinstance(node, SequenceNode) and node.tag == 'tag:yaml.org,2002:seq':
            child_context = {'automations': 'automation', 'actions': 'action',
                             'choices': 'choice', 'triggers': 'trigger'}.get(context, '')
            return ('sequence', tuple(visit(child, child_context, depth + 1)
                                      for child in node.value))
        if not isinstance(node, MappingNode) or node.tag != 'tag:yaml.org,2002:map':
            raise ValueError('Unsupported YAML node')
        fields = {}
        for key, value in node.value:
            if not isinstance(key, ScalarNode) or key.tag != STR:
                raise ValueError('Only string mapping keys are supported')
            name = key.value
            if context == 'automation':
                name = ALIASES.get(name, name)
            elif context == 'action' and name == 'service':
                name = 'action'
            elif context == 'trigger' and name == 'platform':
                name = 'trigger'
            if name in fields:
                raise ValueError('Duplicate or ambiguous mapping key')
            child_context = ''
            if context == 'automation' and name in ('actions', 'triggers'):
                child_context = name
            elif context == 'action':
                if name in ('sequence', 'then', 'else', 'parallel'):
                    child_context = 'actions'
                elif name == 'choose':
                    child_context = 'choices'
                elif name == 'default':
                    child_context = 'actions'
                elif name == 'repeat':
                    child_context = 'repeat'
            elif context in ('choice', 'repeat') and name == 'sequence':
                child_context = 'actions'
            fields[name] = visit(value, child_context, depth + 1)
        # HA evaluates variables in insertion order. User data can also expose
        # ordering to templates, so ignore key order only in structural blocks.
        if context in ('automation', 'action', 'trigger', 'choice', 'repeat'):
            return ('mapping', frozenset(fields.items()))
        return ('ordered-mapping', tuple(fields.items()))

    if any(not isinstance(node, MappingNode) for node in root.value):
        raise ValueError('Expected automation mappings')
    return visit(root, 'automations')


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)


def committed(ref):
    entry = git('ls-tree', '-z', ref, '--', 'automations.yaml')
    metadata, path = entry.rstrip(b'\0').split(b'\t')
    mode, kind, oid = metadata.split()
    if path != b'automations.yaml' or kind != b'blob' or mode not in (b'100644', b'100755'):
        raise ValueError('Expected a regular tracked automation file')
    if int(git('cat-file', '-s', oid.decode())) > 4 * 1024 * 1024:
        raise ValueError('Automation file too large')
    return mode, git('cat-file', 'blob', oid.decode())


def equivalent(target, source):
    mode, expected = committed(target)
    if source == '--worktree':
        # Do not follow symlinks, even when their contents happen to match.
        fd = os.open('automations.yaml', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                return False
            actual_mode = b'100755' if info.st_mode & stat.S_IXUSR else b'100644'
            actual = stream.read(4 * 1024 * 1024 + 1)
    else:
        actual_mode, actual = committed(source)
    return mode == actual_mode and canonical(expected) == canonical(actual)


if __name__ == '__main__':
    try:
        matches = len(sys.argv) == 3 and equivalent(*sys.argv[1:])
    except (OSError, ValueError, yaml.YAMLError, subprocess.SubprocessError, RecursionError):
        matches = False
    sys.exit(0 if matches else 1)
