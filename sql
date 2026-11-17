-- ============ PROFILES TABLE ============
-- One row per registered user. Holds their public info.
CREATE TABLE profiles (
  id uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  full_name text NOT NULL,
  email text NOT NULL,
  email_normalized text NOT NULL UNIQUE,   -- lowercased email; UNIQUE = no duplicates
  phone_e164 text NOT NULL UNIQUE,          -- +2547XXXXXXXX; UNIQUE = no duplicates
  dob date NOT NULL,                        -- date of birth
  gender text,
  county text,
  institution text,                         -- OPTIONAL. No .ac.ke requirement.
  course text,
  intention text,
  bio text,
  photo_url text,
  is_verified boolean DEFAULT false,
  is_admin boolean DEFAULT false,           -- true = can access admin dashboard
  created_at timestamptz DEFAULT now()
);

-- Turn on Row Level Security. Without this, anyone with the anon key
-- could read/write ANY row. With it, only the rules below are allowed.
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users read own profile"
  ON profiles FOR SELECT USING (auth.uid() = id);

CREATE POLICY "users update own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id);

-- ============ LIKES TABLE ============
CREATE TABLE likes (
  id bigserial PRIMARY KEY,
  liker uuid REFERENCES profiles(id) ON DELETE CASCADE,
  likee uuid REFERENCES profiles(id) ON DELETE CASCADE,
  is_super boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  UNIQUE (liker, likee)   -- can't like the same person twice
);

ALTER TABLE likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "see likes involving you"
  ON likes FOR SELECT USING (auth.uid() = liker OR auth.uid() = likee);

CREATE POLICY "insert own likes"
  ON likes FOR INSERT WITH CHECK (auth.uid() = liker);

-- ============ MATCHES TABLE ============
CREATE TABLE matches (
  id bigserial PRIMARY KEY,
  user_a uuid REFERENCES profiles(id) ON DELETE CASCADE,
  user_b uuid REFERENCES profiles(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE (user_a, user_b)
);

ALTER TABLE matches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "see own matches"
  ON matches FOR SELECT USING (auth.uid() = user_a OR auth.uid() = user_b);

-- ============ MESSAGES TABLE ============
CREATE TABLE messages (
  id bigserial PRIMARY KEY,
  match_id bigint REFERENCES matches(id) ON DELETE CASCADE,
  sender uuid REFERENCES profiles(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "read messages in own matches"
  ON messages FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM matches m
      WHERE m.id = match_id
        AND (m.user_a = auth.uid() OR m.user_b = auth.uid())
    )
  );

CREATE POLICY "send messages in own matches"
  ON messages FOR INSERT WITH CHECK (
    sender = auth.uid()
    AND EXISTS (
      SELECT 1 FROM matches m
      WHERE m.id = match_id
        AND (m.user_a = auth.uid() OR m.user_b = auth.uid())
    )
  );

-- ============ SUBSCRIPTIONS TABLE ============
CREATE TABLE subscriptions (
  id bigserial PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  plan text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  started_at timestamptz DEFAULT now(),
  expires_at timestamptz
);

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "see own subs"
  ON subscriptions FOR SELECT USING (auth.uid() = user_id);

-- ============ PAYMENTS TABLE ============
CREATE TABLE payments (
  id bigserial PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  paystack_reference text UNIQUE NOT NULL,   -- idempotent: one row per charge
  amount int NOT NULL,                        -- in kobo (KSh × 100)
  status text NOT NULL,
  plan text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "see own payments"
  ON payments FOR SELECT USING (auth.uid() = user_id);

-- ============ TRIALS TABLE ============
CREATE TABLE trials (
  user_id uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);

ALTER TABLE trials ENABLE ROW LEVEL SECURITY;

CREATE POLICY "see own trial"
  ON trials FOR SELECT USING (auth.uid() = user_id);

-- ============ BLOCKS & REPORTS ============
CREATE TABLE blocks (
  id bigserial PRIMARY KEY,
  blocker uuid REFERENCES profiles(id) ON DELETE CASCADE,
  blocked uuid REFERENCES profiles(id) ON DELETE CASCADE,
  UNIQUE (blocker, blocked)
);

CREATE TABLE reports (
  id bigserial PRIMARY KEY,
  reporter uuid REFERENCES profiles(id),
  reported uuid REFERENCES profiles(id),
  reason text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "own blocks" ON blocks FOR ALL USING (auth.uid() = blocker);
CREATE POLICY "report insert" ON reports FOR INSERT WITH CHECK (auth.uid() = reporter);

-- ============ AUTO-CREATE PROFILE ON SIGNUP ============
-- When a user signs up, Supabase inserts into auth.users.
-- This trigger copies their name/phone/dob into our profiles table automatically.
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, full_name, email, email_normalized, phone_e164, dob)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    lower(trim(new.email)),
    new.raw_user_meta_data->>'phone',
    (new.raw_user_meta_data->>'dob')::date
  );
  RETURN new;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE handle_new_user();

-- ============ REAL-TIME MESSAGES ============
-- Tells Supabase to push new messages to subscribed clients.
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
