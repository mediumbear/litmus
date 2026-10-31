"""A store of items."""

import json


class Store:
    """Items, saved as JSON."""

    # Where the items are saved.
    path = "items.json"

    def __init__(self):
        self.items = []

    def add(self, item):
        self.items.append(item)
        return len(self.items)

    @property
    def count(self):
        return len(self.items)

    def save(self):
        with open(self.path, "w") as f:
            json.dump(self.items, f)

    def load(self):
        with open(self.path) as f:
            self.items = json.load(f)

    def clear(self):
        self.items = []

    def first(self):
        return self.items[0]

    def last(self):
        return self.items[-1]

    def open(self):
        return [i for i in self.items if i.open]

    def closed(self):
        return [i for i in self.items if i.closed]

    def __len__(self):
        return len(self.items)


def main():
    Store().save()
