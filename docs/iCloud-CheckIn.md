- Trigger points
      - iOS: Pull-to-refresh on RecipeCollectionView.
      - macOS: ⌘R (SwiftUI’s refreshable equivalent).
  - What it does
      - Calls the view’s .refreshable block → loadRecipes(skipCache: true) (or loadRecipesForCategory(...,
        skipCache: true) when in a category).
      - skipCache: true bypasses local JSON caches and goes straight to CloudKit:
          - Home: CloudKitManager.loadRandomRecipes(..., skipCache: true) → queries the correct database/
            zone (private for owner/personal, shared DB otherwise), pulls fresh records, then rewrites the
            on-disk cache.
          - Category: CloudKitManager.loadRecipes(for: source, category: category, skipCache: true) → same
            direct CloudKit fetch, then rewrites the cache.
      - After fetch, recipesRefreshed posts and AppViewModel updates recipes/randomRecipes, so UI shows the
        new data immediately.
  - What it isn’t
      - It doesn’t “force an upload”; saves happen when you hit Create/Update. Refresh just forces a read
        from CloudKit, bypassing cached data.