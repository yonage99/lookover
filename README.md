# Lookover

Send a photo of your outfit, makeup, skin, nails or hair and get a review from a stylist. The community can rate looks too.

- `index.html` is the whole web app. It is deployed by Vercel from the `main` branch.
- `supabase/` holds the database setup (tables, security rules, storage), applied in order.

The Supabase publishable key in `index.html` is meant to be public. Data is protected by row level security in the database.
