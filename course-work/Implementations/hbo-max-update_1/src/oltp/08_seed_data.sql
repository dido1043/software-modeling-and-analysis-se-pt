/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    08_seed_data.sql
   Purpose: Populate HBOMaxOLTP with a realistic, DETERMINISTIC demo data set.
   Target:  Microsoft SQL Server 2019+
   Depends: 01-07 must have run first (the triggers in 06 are active while the
            data is loaded and keep the derived columns and the audit trail
            correct).

   Data window : subscribers register between 2024-01-01 and 2026-09-20; the
                 data set is "as of" 2026-10-20 - nothing happens after that day.
   Volume      : 14 countries, 12 languages, 14 genres, 11 studios, 50 people,
                 51 titles with their seasons and episodes, 7 plans, 6 coupons,
                 600 subscribers with profiles, devices, payment methods,
                 subscriptions (trials, plan changes, cancellations,
                 re-subscriptions), invoices and payments, ~40 000 watch
                 sessions, watchlists, reviews and downloads.
   Determinism : there is no RAND() / NEWID(). Every "random" choice comes from
                 the helper dbo.ufn_SeedHash (an MD5 of the row number and a
                 salt), so every run produces exactly the same data.
   Re-runnable : step 0 empties every table and reseeds the identities, so the
                 script can be run any number of times.

   Generation order follows the foreign keys and the triggers:
     reference data -> catalogue -> plans/coupons -> subscribers ->
     subscriptions (then plan changes, trial ends, cancellations, so the audit
     trigger writes a real history) -> profiles -> devices -> payment methods
     -> coupons applied -> invoices -> payments (the trigger settles invoices)
     -> past-due subscriptions -> watch sessions -> watchlists -> reviews (the
     trigger maintains title ratings) -> downloads -> last-seen / last-login.
   ============================================================================= */

USE HBOMaxOLTP;
GO

SET NOCOUNT ON;
GO

/* =============================================================================
   0. EMPTY EVERY TABLE AND RESEED THE IDENTITIES
   Children before parents. Identities are reseeded only on tables that have
   ever held rows, so the next row always gets ID 1.
   ============================================================================= */
DELETE FROM play.Download;
DELETE FROM play.Review;
DELETE FROM play.Watchlist;
DELETE FROM play.WatchSession;
DELETE FROM bill.Payment;
DELETE FROM bill.Invoice;
DELETE FROM bill.SubscriptionCoupon;
DELETE FROM bill.Coupon;
DELETE FROM bill.PaymentMethod;
DELETE FROM audit.SubscriptionChangeLog;
DELETE FROM acct.Subscription;
DELETE FROM acct.Device;
DELETE FROM acct.Profile;
DELETE FROM acct.Subscriber;
DELETE FROM acct.[Plan];
DELETE FROM cat.TitleAvailability;
DELETE FROM cat.TitleLanguageTrack;
DELETE FROM cat.Credit;
DELETE FROM cat.TitleGenre;
DELETE FROM cat.Episode;
DELETE FROM cat.Season;
DELETE FROM cat.Title;
DELETE FROM cat.Studio;
DELETE FROM cat.Person;
DELETE FROM cat.Genre;
DELETE FROM cat.Language;
DELETE FROM geo.Country;

DECLARE @Reseed NVARCHAR(MAX);
SELECT @Reseed = STRING_AGG(CAST(N'DBCC CHECKIDENT (''' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
                                 + N''', RESEED, 0) WITH NO_INFOMSGS;' AS NVARCHAR(MAX)), N' ')
FROM sys.identity_columns AS ic
INNER JOIN sys.tables  AS t ON t.object_id = ic.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name IN ('geo', 'acct', 'cat', 'play', 'bill', 'audit')
  AND ic.last_value IS NOT NULL;

IF @Reseed IS NOT NULL EXEC sys.sp_executesql @Reseed;
GO

/* =============================================================================
   Helper used only by this script: a deterministic pseudo-random non-negative
   INT from two numbers and a salt. Dropped again at the end.
   ============================================================================= */
CREATE OR ALTER FUNCTION dbo.ufn_SeedHash (@A BIGINT, @B BIGINT, @Salt INT)
RETURNS INT
AS
BEGIN
    RETURN CAST(CAST(HASHBYTES('MD5', CONCAT(@A, ':', @B, ':', @Salt)) AS BINARY(4)) AS INT) & 2147483647;
END
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @AsOf DATE = '2026-10-20';
DECLARE @AsOfEnd DATETIME2(0) = DATEADD(DAY, 1, CAST(@AsOf AS DATETIME2(0)));
DECLARE @Mark BIGINT;

BEGIN TRANSACTION;

/* ---- tally table 1..60000 ------------------------------------------------- */
DROP TABLE IF EXISTS #N;
CREATE TABLE #N (n INT NOT NULL PRIMARY KEY);
INSERT INTO #N (n)
SELECT TOP (60000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

/* =============================================================================
   1. REFERENCE DATA
   ============================================================================= */
INSERT INTO geo.Country (IsoAlpha2, IsoAlpha3, CountryName, RegionName, CurrencyCode, LaunchDate, IsLaunched)
VALUES ('US', 'USA', N'United States',  N'North America', 'USD', '2020-05-27', 1),
       ('MX', 'MEX', N'Mexico',         N'Latin America', 'MXN', '2021-06-29', 1),
       ('BR', 'BRA', N'Brazil',         N'Latin America', 'BRL', '2021-06-29', 1),
       ('AR', 'ARG', N'Argentina',      N'Latin America', 'ARS', '2021-06-29', 1),
       ('CO', 'COL', N'Colombia',       N'Latin America', 'COP', '2021-06-29', 1),
       ('ES', 'ESP', N'Spain',          N'Europe',        'EUR', '2021-10-26', 1),
       ('SE', 'SWE', N'Sweden',         N'Europe',        'SEK', '2021-10-26', 1),
       ('NL', 'NLD', N'Netherlands',    N'Europe',        'EUR', '2022-03-08', 1),
       ('PL', 'POL', N'Poland',         N'Europe',        'PLN', '2022-03-08', 1),
       ('BG', 'BGR', N'Bulgaria',       N'Europe',        'EUR', '2022-03-08', 1),
       ('PT', 'PRT', N'Portugal',       N'Europe',        'EUR', '2022-03-08', 1),
       ('FR', 'FRA', N'France',         N'Europe',        'EUR', '2024-06-11', 1),
       ('DE', 'DEU', N'Germany',        N'Europe',        'EUR', NULL,         0),
       ('GB', 'GBR', N'United Kingdom', N'Europe',        'GBP', NULL,         0);

INSERT INTO cat.Language (IsoCode, LanguageName)
VALUES ('en', N'English'), ('es', N'Spanish'), ('pt', N'Portuguese'), ('fr', N'French'),
       ('de', N'German'),  ('bg', N'Bulgarian'), ('pl', N'Polish'),  ('nl', N'Dutch'),
       ('sv', N'Swedish'), ('it', N'Italian'),  ('ja', N'Japanese'), ('ko', N'Korean');

INSERT INTO cat.Genre (GenreName, Description)
VALUES (N'Drama',          N'Character-driven stories with serious tone'),
       (N'Comedy',         N'Stories meant to make the audience laugh'),
       (N'Fantasy',        N'Magic, mythical worlds and creatures'),
       (N'Sci-Fi',         N'Science fiction and speculative futures'),
       (N'Crime',          N'Criminals, detectives and the justice system'),
       (N'Thriller',       N'Suspense, tension and danger'),
       (N'Horror',         N'Stories meant to frighten'),
       (N'Documentary',    N'Non-fiction films and series'),
       (N'Animation',      N'Animated films and series'),
       (N'Kids & Family',  N'Suitable for children and family viewing'),
       (N'Romance',        N'Love stories'),
       (N'Action',         N'Fights, chases and spectacle'),
       (N'Reality',        N'Unscripted television'),
       (N'Stand-Up',       N'Stand-up comedy specials');

INSERT INTO cat.Studio (StudioName, FoundedYear, HeadquartersCountryID, Website)
SELECT v.StudioName, v.FoundedYear, c.CountryID, v.Website
FROM (VALUES (N'HBO',                      1972, N'https://www.hbo.com'),
             (N'Warner Bros. Pictures',    1923, N'https://www.warnerbros.com'),
             (N'Warner Bros. Television',  1955, N'https://www.warnerbros.com/tv'),
             (N'Warner Bros. Animation',   1980, N'https://www.warnerbros.com/animation'),
             (N'DC Studios',               2022, N'https://www.dc.com'),
             (N'Cartoon Network Studios',  1994, N'https://www.cartoonnetwork.com'),
             (N'HBO Documentary Films',    1979, N'https://www.hbo.com/documentaries'),
             (N'CNN Films',                2012, N'https://www.cnn.com/films'),
             (N'Legendary Pictures',       2000, N'https://www.legendary.com'),
             (N'A24',                      2012, N'https://a24films.com'),
             (N'Sesame Workshop',          1968, N'https://www.sesameworkshop.org')
     ) AS v (StudioName, FoundedYear, Website)
CROSS JOIN geo.Country AS c
WHERE c.IsoAlpha2 = 'US';

INSERT INTO cat.Person (FullName, BirthCountryID, Gender)
SELECT v.FullName, c.CountryID, v.Gender
FROM (VALUES (N'Pedro Pascal', NULL, 'M'),       (N'Bella Ramsey', 'GB', 'F'),
             (N'Craig Mazin', 'US', 'M'),        (N'Neil Druckmann', NULL, 'M'),
             (N'Emma D''Arcy', 'GB', 'X'),       (N'Matt Smith', 'GB', 'M'),
             (N'Ryan Condal', 'US', 'M'),        (N'Emilia Clarke', 'GB', 'F'),
             (N'Kit Harington', 'GB', 'M'),      (N'Peter Dinklage', 'US', 'M'),
             (N'Brian Cox', 'GB', 'M'),          (N'Jeremy Strong', 'US', 'M'),
             (N'Jesse Armstrong', 'GB', 'M'),    (N'Mike White', 'US', 'M'),
             (N'Jennifer Coolidge', 'US', 'F'),  (N'Zendaya', 'US', 'F'),
             (N'Sam Levinson', 'US', 'M'),       (N'James Gandolfini', 'US', 'M'),
             (N'David Chase', 'US', 'M'),        (N'Matthew McConaughey', 'US', 'M'),
             (N'Bill Hader', 'US', 'M'),         (N'Jean Smart', 'US', 'F'),
             (N'Colin Farrell', NULL, 'M'),      (N'Timothee Chalamet', 'US', 'M'),
             (N'Denis Villeneuve', NULL, 'M'),   (N'Robert Pattinson', 'GB', 'M'),
             (N'Matt Reeves', 'US', 'M'),        (N'Margot Robbie', NULL, 'F'),
             (N'Greta Gerwig', 'US', 'F'),       (N'Joaquin Phoenix', 'US', 'M'),
             (N'Todd Phillips', 'US', 'M'),      (N'Christopher Nolan', 'GB', 'M'),
             (N'Christian Bale', 'GB', 'M'),     (N'Keanu Reeves', NULL, 'M'),
             (N'Lana Wachowski', 'US', 'F'),     (N'Kate Winslet', 'GB', 'F'),
             (N'Noah Wyle', 'US', 'M'),          (N'Jennifer Aniston', 'US', 'F'),
             (N'Daniel Radcliffe', 'GB', 'M'),   (N'Leonardo DiCaprio', 'US', 'M'),
             (N'John Cena', 'US', 'M'),          (N'David Corenswet', 'US', 'M'),
             (N'James Gunn', 'US', 'M'),         (N'Tom Hardy', 'GB', 'M'),
             (N'Charlize Theron', NULL, 'F'),    (N'George Miller', NULL, 'M'),
             (N'Jared Harris', 'GB', 'M'),       (N'Dominic West', 'GB', 'M'),
             (N'Idris Elba', 'GB', 'M'),         (N'Alex Garland', 'GB', 'M')
     ) AS v (FullName, BirthIso, Gender)
LEFT JOIN geo.Country AS c ON c.IsoAlpha2 = v.BirthIso;

/* =============================================================================
   2. CATALOGUE - titles, genres, seasons, episodes, credits, tracks, licences
   #T drives everything. Pop is a 1..10 popularity weight used when sessions
   pick a title.
   ============================================================================= */
DROP TABLE IF EXISTS #T;
CREATE TABLE #T
(
    Seq          INT           NOT NULL PRIMARY KEY,
    PrimaryTitle NVARCHAR(200) NOT NULL,
    TitleType    VARCHAR(12)   NOT NULL,
    ReleaseYear  SMALLINT      NOT NULL,
    Rating       VARCHAR(5)    NOT NULL,
    Runtime      SMALLINT      NULL,
    StudioName   NVARCHAR(100) NOT NULL,
    IsHbo        BIT           NOT NULL,
    Imdb         DECIMAL(3,1)  NULL,
    Budget       DECIMAL(14,2) NULL,
    AddedAt      DATE          NOT NULL,
    RemovedAt    DATE          NULL,
    Seasons      TINYINT       NOT NULL,
    EpsPerSeason SMALLINT      NOT NULL,
    EpRuntime    SMALLINT      NOT NULL,
    G1           NVARCHAR(50)  NOT NULL,
    G2           NVARCHAR(50)  NULL,
    G3           NVARCHAR(50)  NULL,
    Pop          INT           NOT NULL,
    TitleID      INT           NULL
);

INSERT INTO #T (Seq, PrimaryTitle, TitleType, ReleaseYear, Rating, Runtime, StudioName, IsHbo, Imdb, Budget,
                AddedAt, RemovedAt, Seasons, EpsPerSeason, EpRuntime, G1, G2, G3, Pop)
VALUES
 ( 1, N'The Last of Us',          'Series', 2023, 'TV-MA', NULL, N'HBO',                     1, 8.6, NULL, '2023-01-15', NULL,          2,  9, 55, N'Drama',   N'Sci-Fi',   N'Horror',   10),
 ( 2, N'House of the Dragon',     'Series', 2022, 'TV-MA', NULL, N'HBO',                     1, 8.3, NULL, '2022-08-21', NULL,          2,  9, 62, N'Fantasy', N'Drama',    N'Action',   10),
 ( 3, N'Game of Thrones',         'Series', 2011, 'TV-MA', NULL, N'HBO',                     1, 9.2, NULL, '2020-05-27', NULL,          8,  9, 57, N'Fantasy', N'Drama',    N'Action',    9),
 ( 4, N'Succession',              'Series', 2018, 'TV-MA', NULL, N'HBO',                     1, 8.8, NULL, '2020-05-27', NULL,          4, 10, 60, N'Drama',   N'Comedy',   NULL,         7),
 ( 5, N'The White Lotus',         'Series', 2021, 'TV-MA', NULL, N'HBO',                     1, 7.9, NULL, '2021-07-11', NULL,          3,  7, 58, N'Comedy',  N'Drama',    N'Thriller',  8),
 ( 6, N'Euphoria',                'Series', 2019, 'TV-MA', NULL, N'HBO',                     1, 8.3, NULL, '2020-05-27', NULL,          2,  8, 55, N'Drama',   NULL,        NULL,         7),
 ( 7, N'The Sopranos',            'Series', 1999, 'TV-MA', NULL, N'HBO',                     1, 9.2, NULL, '2020-05-27', NULL,          6, 13, 55, N'Crime',   N'Drama',    NULL,         6),
 ( 8, N'True Detective',          'Series', 2014, 'TV-MA', NULL, N'HBO',                     1, 8.9, NULL, '2020-05-27', NULL,          4,  7, 58, N'Crime',   N'Thriller', N'Drama',     6),
 ( 9, N'Westworld',               'Series', 2016, 'TV-MA', NULL, N'HBO',                     1, 8.5, NULL, '2020-05-27', '2022-12-18',  4,  9, 60, N'Sci-Fi',  N'Drama',    NULL,         1),
 (10, N'Barry',                   'Series', 2018, 'TV-MA', NULL, N'HBO',                     1, 8.4, NULL, '2020-05-27', NULL,          4,  8, 30, N'Comedy',  N'Crime',    NULL,         5),
 (11, N'Hacks',                   'Series', 2021, 'TV-MA', NULL, N'HBO',                     1, 8.2, NULL, '2021-05-13', NULL,          4,  9, 30, N'Comedy',  N'Drama',    NULL,         5),
 (12, N'The Penguin',             'Series', 2024, 'TV-MA', NULL, N'DC Studios',              1, 8.6, NULL, '2024-09-19', NULL,          1,  8, 60, N'Crime',   N'Drama',    N'Action',    8),
 (13, N'Peacemaker',              'Series', 2022, 'TV-MA', NULL, N'DC Studios',              1, 8.3, NULL, '2022-01-13', NULL,          2,  8, 45, N'Action',  N'Comedy',   NULL,         6),
 (14, N'Silicon Valley',          'Series', 2014, 'TV-MA', NULL, N'HBO',                     1, 8.5, NULL, '2020-05-27', NULL,          6,  9, 28, N'Comedy',  NULL,        NULL,         4),
 (15, N'Veep',                    'Series', 2012, 'TV-MA', NULL, N'HBO',                     1, 8.4, NULL, '2020-05-27', NULL,          7,  9, 28, N'Comedy',  NULL,        NULL,         3),
 (16, N'Chernobyl',               'Series', 2019, 'TV-MA', NULL, N'HBO',                     1, 9.3, NULL, '2020-05-27', NULL,          1,  5, 65, N'Drama',   N'Thriller', NULL,         6),
 (17, N'Band of Brothers',        'Series', 2001, 'TV-MA', NULL, N'HBO',                     1, 9.4, NULL, '2020-05-27', NULL,          1, 10, 60, N'Drama',   N'Action',   NULL,         4),
 (18, N'Friends',                 'Series', 1994, 'TV-14', NULL, N'Warner Bros. Television', 0, 8.9, NULL, '2020-05-27', NULL,         10, 24, 22, N'Comedy',  N'Romance',  NULL,         9),
 (19, N'The Big Bang Theory',     'Series', 2007, 'TV-PG', NULL, N'Warner Bros. Television', 0, 8.2, NULL, '2020-05-27', NULL,         12, 24, 21, N'Comedy',  NULL,        NULL,         7),
 (20, N'Rick and Morty',          'Series', 2013, 'TV-MA', NULL, N'Cartoon Network Studios', 0, 9.1, NULL, '2020-05-27', NULL,          7, 10, 22, N'Animation', N'Comedy', N'Sci-Fi',    6),
 (21, N'Adventure Time',          'Series', 2010, 'TV-PG', NULL, N'Cartoon Network Studios', 0, 8.6, NULL, '2020-05-27', NULL,         10, 12, 11, N'Animation', N'Kids & Family', NULL,  4),
 (22, N'Sesame Street',           'Series', 1969, 'TV-Y',  NULL, N'Sesame Workshop',         0, 8.1, NULL, '2020-05-27', NULL,          2, 10, 30, N'Kids & Family', NULL,   NULL,         3),
 (23, N'Tiny Toons Looniversity', 'Series', 2023, 'TV-Y7', NULL, N'Warner Bros. Animation',  1, 6.0, NULL, '2023-09-08', NULL,          2, 10, 22, N'Animation', N'Kids & Family', NULL,  3),
 (24, N'The Pitt',                'Series', 2025, 'TV-MA', NULL, N'Warner Bros. Television', 1, 8.9, NULL, '2025-01-09', NULL,          1, 15, 50, N'Drama',   NULL,        NULL,         8),
 (25, N'Industry',                'Series', 2020, 'TV-MA', NULL, N'HBO',                     1, 7.6, NULL, '2020-11-09', NULL,          3,  8, 55, N'Drama',   NULL,        NULL,         4),
 (26, N'Curb Your Enthusiasm',    'Series', 2000, 'TV-MA', NULL, N'HBO',                     1, 8.8, NULL, '2020-05-27', NULL,         12, 10, 28, N'Comedy',  NULL,        NULL,         3),
 (27, N'Big Little Lies',         'Series', 2017, 'TV-MA', NULL, N'HBO',                     1, 8.5, NULL, '2020-05-27', NULL,          2,  7, 55, N'Drama',   N'Crime',    NULL,         4),
 (28, N'Mare of Easttown',        'Series', 2021, 'TV-MA', NULL, N'HBO',                     1, 8.4, NULL, '2021-04-18', NULL,          1,  7, 58, N'Crime',   N'Drama',    N'Thriller',  5),
 (29, N'The Wire',                'Series', 2002, 'TV-MA', NULL, N'HBO',                     1, 9.3, NULL, '2020-05-27', NULL,          5, 12, 58, N'Crime',   N'Drama',    NULL,         4),
 (30, N'Dune: Prophecy',          'Series', 2024, 'TV-MA', NULL, N'HBO',                     1, 7.0, NULL, '2024-11-17', NULL,          1,  6, 60, N'Sci-Fi',  N'Drama',    NULL,         6),
 (31, N'The Gilded Age',          'Series', 2022, 'TV-PG', NULL, N'HBO',                     1, 8.0, NULL, '2022-01-24', NULL,          3,  8, 55, N'Drama',   NULL,        NULL,         3),
 (32, N'Dune: Part Two',          'Movie',  2024, 'PG-13', 166,  N'Legendary Pictures',      0, 8.5, 190000000, '2024-04-16', NULL,     0,  0,  0, N'Sci-Fi',  N'Action',   N'Drama',     9),
 (33, N'The Batman',              'Movie',  2022, 'PG-13', 176,  N'Warner Bros. Pictures',   0, 7.8, 185000000, '2022-04-18', NULL,     0,  0,  0, N'Action',  N'Crime',    NULL,         8),
 (34, N'Barbie',                  'Movie',  2023, 'PG-13', 114,  N'Warner Bros. Pictures',   0, 6.8, 145000000, '2023-09-15', NULL,     0,  0,  0, N'Comedy',  N'Fantasy',  NULL,         8),
 (35, N'Joker',                   'Movie',  2019, 'R',     122,  N'Warner Bros. Pictures',   0, 8.4,  55000000, '2020-05-27', NULL,     0,  0,  0, N'Crime',   N'Thriller', N'Drama',     6),
 (36, N'Wonka',                   'Movie',  2023, 'PG',    116,  N'Warner Bros. Pictures',   0, 7.0, 125000000, '2024-03-08', NULL,     0,  0,  0, N'Kids & Family', N'Fantasy', N'Comedy', 6),
 (37, N'The Matrix',              'Movie',  1999, 'R',     136,  N'Warner Bros. Pictures',   0, 8.7,  63000000, '2020-05-27', NULL,     0,  0,  0, N'Sci-Fi',  N'Action',   NULL,         5),
 (38, N'Inception',               'Movie',  2010, 'PG-13', 148,  N'Warner Bros. Pictures',   0, 8.8, 160000000, '2020-05-27', NULL,     0,  0,  0, N'Sci-Fi',  N'Thriller', N'Action',    6),
 (39, N'Harry Potter and the Sorcerer''s Stone', 'Movie', 2001, 'PG', 152, N'Warner Bros. Pictures', 0, 7.7, 125000000, '2020-05-27', NULL, 0, 0, 0, N'Fantasy', N'Kids & Family', NULL, 7),
 (40, N'The Dark Knight',         'Movie',  2008, 'PG-13', 152,  N'Warner Bros. Pictures',   0, 9.0, 185000000, '2020-05-27', NULL,     0,  0,  0, N'Action',  N'Crime',    N'Drama',     7),
 (41, N'Mad Max: Fury Road',      'Movie',  2015, 'R',     120,  N'Warner Bros. Pictures',   0, 8.1, 150000000, '2020-05-27', NULL,     0,  0,  0, N'Action',  N'Sci-Fi',   NULL,         5),
 (42, N'Civil War',               'Movie',  2024, 'R',     109,  N'A24',                     0, 7.0,  50000000, '2024-09-13', NULL,     0,  0,  0, N'Action',  N'Thriller', N'Drama',     5),
 (43, N'Godzilla x Kong: The New Empire', 'Movie', 2024, 'PG-13', 115, N'Legendary Pictures', 0, 6.0, 135000000, '2024-07-15', NULL,  0,  0,  0, N'Action',  N'Sci-Fi',   NULL,         4),
 (44, N'Elvis',                   'Movie',  2022, 'PG-13', 159,  N'Warner Bros. Pictures',   0, 7.3,  85000000, '2022-09-02', NULL,     0,  0,  0, N'Drama',   N'Romance',  NULL,         3),
 (45, N'Beetlejuice Beetlejuice', 'Movie',  2024, 'PG-13', 104,  N'Warner Bros. Pictures',   0, 6.6,  99000000, '2024-12-06', NULL,     0,  0,  0, N'Comedy',  N'Fantasy',  N'Horror',    5),
 (46, N'Superman',                'Movie',  2025, 'PG-13', 129,  N'DC Studios',              0, 7.2, 225000000, '2025-09-19', NULL,     0,  0,  0, N'Action',  N'Sci-Fi',   NULL,         6),
 (47, N'The Lego Movie',          'Movie',  2014, 'PG',    100,  N'Warner Bros. Pictures',   0, 7.7,  60000000, '2020-05-27', NULL,     0,  0,  0, N'Animation', N'Kids & Family', N'Comedy', 4),
 (48, N'Navalny',                 'Documentary', 2022, 'R', 98,  N'CNN Films',               0, 7.6, NULL,      '2022-04-24', NULL,     0,  0,  0, N'Documentary', NULL,     NULL,         2),
 (49, N'George Carlin''s American Dream', 'Documentary', 2022, 'TV-MA', 214, N'HBO Documentary Films', 1, 8.4, NULL, '2022-05-20', NULL, 0, 0, 0, N'Documentary', N'Comedy', NULL, 2),
 (50, N'Jerrod Carmichael: Rothaniel', 'StandUp', 2022, 'TV-MA', 52, N'HBO',                 1, 7.5, NULL,      '2022-04-02', NULL,     0,  0,  0, N'Stand-Up', NULL,       NULL,         2),
 (51, N'Ramy Youssef: More Feelings',  'StandUp', 2024, 'TV-MA', 60, N'HBO',                 1, 7.0, NULL,      '2024-06-29', NULL,     0,  0,  0, N'Stand-Up', NULL,       NULL,         2);

INSERT INTO cat.Title
    (PrimaryTitle, TitleType, ReleaseYear, MaturityRating, RuntimeMinutes, PosterUrl, TrailerUrl,
     OriginalLanguageID, StudioID, IsHboOriginal, ProductionBudgetUsd, ImdbRating,
     AddedToCatalogAt, RemovedFromCatalogAt)
SELECT t.PrimaryTitle, t.TitleType, t.ReleaseYear, t.Rating, t.Runtime,
       N'https://img.example.com/titles/' + CAST(t.Seq AS NVARCHAR(4)) + N'/poster.jpg',
       N'https://video.example.com/trailers/' + CAST(t.Seq AS NVARCHAR(4)) + N'.m3u8',
       l.LanguageID, st.StudioID, t.IsHbo, t.Budget, t.Imdb,
       CAST(t.AddedAt AS DATETIME2(0)), CAST(t.RemovedAt AS DATETIME2(0))
FROM #T AS t
INNER JOIN cat.Language AS l  ON l.IsoCode     = 'en'
INNER JOIN cat.Studio   AS st ON st.StudioName = t.StudioName
ORDER BY t.Seq;

UPDATE x SET TitleID = t.TitleID
FROM #T AS x INNER JOIN cat.Title AS t ON t.PrimaryTitle = x.PrimaryTitle;

INSERT INTO cat.TitleGenre (TitleID, GenreID, IsPrimaryGenre)
SELECT t.TitleID, g.GenreID, CASE WHEN v.Pos = 1 THEN 1 ELSE 0 END
FROM #T AS t
CROSS APPLY (VALUES (1, t.G1), (2, t.G2), (3, t.G3)) AS v (Pos, GenreName)
INNER JOIN cat.Genre AS g ON g.GenreName = v.GenreName;

INSERT INTO cat.Season (TitleID, SeasonNumber, SeasonTitle, ReleaseYear)
SELECT t.TitleID, n.n, N'Season ' + CAST(n.n AS NVARCHAR(3)),
       CASE WHEN t.ReleaseYear + n.n - 1 > 2025 THEN 2025 ELSE t.ReleaseYear + n.n - 1 END
FROM #T AS t
INNER JOIN #N AS n ON n.n <= t.Seasons
ORDER BY t.Seq, n.n;

/* episodes - the trigger cat.trg_Episode_SyncSeasonCount fills Season.EpisodeCount */
INSERT INTO cat.Episode (SeasonID, EpisodeNumber, EpisodeTitle, RuntimeMinutes, AirDate)
SELECT s.SeasonID, n.n,
       N'Episode ' + CAST(n.n AS NVARCHAR(4)),
       t.EpRuntime + dbo.ufn_SeedHash(s.SeasonID, n.n, 1) % 9 - 4,
       DATEADD(DAY, 7 * (n.n - 1),
               DATEFROMPARTS(s.ReleaseYear, 1 + dbo.ufn_SeedHash(s.SeasonID, 0, 2) % 8, 1))
FROM cat.Season AS s
INNER JOIN #T AS t ON t.TitleID = s.TitleID
INNER JOIN #N AS n ON n.n <= t.EpsPerSeason
ORDER BY s.SeasonID, n.n;

INSERT INTO cat.Credit (TitleID, PersonID, CreditRole, CharacterName, BillingOrder)
SELECT t.TitleID, p.PersonID, v.CreditRole, v.CharacterName, v.BillingOrder
FROM (VALUES
    (N'The Last of Us', N'Pedro Pascal', 'Actor', N'Joel Miller', 1),
    (N'The Last of Us', N'Bella Ramsey', 'Actor', N'Ellie Williams', 2),
    (N'The Last of Us', N'Craig Mazin', 'Writer', NULL, NULL),
    (N'The Last of Us', N'Craig Mazin', 'Producer', NULL, NULL),
    (N'The Last of Us', N'Neil Druckmann', 'Writer', NULL, NULL),
    (N'House of the Dragon', N'Emma D''Arcy', 'Actor', N'Rhaenyra Targaryen', 1),
    (N'House of the Dragon', N'Matt Smith', 'Actor', N'Daemon Targaryen', 2),
    (N'House of the Dragon', N'Ryan Condal', 'Writer', NULL, NULL),
    (N'Game of Thrones', N'Emilia Clarke', 'Actor', N'Daenerys Targaryen', 1),
    (N'Game of Thrones', N'Kit Harington', 'Actor', N'Jon Snow', 2),
    (N'Game of Thrones', N'Peter Dinklage', 'Actor', N'Tyrion Lannister', 3),
    (N'Succession', N'Brian Cox', 'Actor', N'Logan Roy', 1),
    (N'Succession', N'Jeremy Strong', 'Actor', N'Kendall Roy', 2),
    (N'Succession', N'Jesse Armstrong', 'Writer', NULL, NULL),
    (N'The White Lotus', N'Jennifer Coolidge', 'Actor', N'Tanya McQuoid', 1),
    (N'The White Lotus', N'Mike White', 'Director', NULL, NULL),
    (N'The White Lotus', N'Mike White', 'Writer', NULL, NULL),
    (N'Euphoria', N'Zendaya', 'Actor', N'Rue Bennett', 1),
    (N'Euphoria', N'Sam Levinson', 'Writer', NULL, NULL),
    (N'Euphoria', N'Sam Levinson', 'Director', NULL, NULL),
    (N'The Sopranos', N'James Gandolfini', 'Actor', N'Tony Soprano', 1),
    (N'The Sopranos', N'David Chase', 'Writer', NULL, NULL),
    (N'True Detective', N'Matthew McConaughey', 'Actor', N'Rust Cohle', 1),
    (N'Barry', N'Bill Hader', 'Actor', N'Barry Berkman', 1),
    (N'Barry', N'Bill Hader', 'Director', NULL, NULL),
    (N'Hacks', N'Jean Smart', 'Actor', N'Deborah Vance', 1),
    (N'The Penguin', N'Colin Farrell', 'Actor', N'Oz Cobb', 1),
    (N'Peacemaker', N'John Cena', 'Actor', N'Christopher Smith', 1),
    (N'Peacemaker', N'James Gunn', 'Writer', NULL, NULL),
    (N'Chernobyl', N'Jared Harris', 'Actor', N'Valery Legasov', 1),
    (N'Chernobyl', N'Craig Mazin', 'Writer', NULL, NULL),
    (N'Mare of Easttown', N'Kate Winslet', 'Actor', N'Mare Sheehan', 1),
    (N'The Wire', N'Dominic West', 'Actor', N'Jimmy McNulty', 1),
    (N'The Wire', N'Idris Elba', 'Actor', N'Stringer Bell', 2),
    (N'Friends', N'Jennifer Aniston', 'Actor', N'Rachel Green', 1),
    (N'The Pitt', N'Noah Wyle', 'Actor', N'Dr. Michael Robinavitch', 1),
    (N'Dune: Part Two', N'Timothee Chalamet', 'Actor', N'Paul Atreides', 1),
    (N'Dune: Part Two', N'Denis Villeneuve', 'Director', NULL, NULL),
    (N'The Batman', N'Robert Pattinson', 'Actor', N'Bruce Wayne', 1),
    (N'The Batman', N'Colin Farrell', 'Actor', N'Oswald Cobblepot', 2),
    (N'The Batman', N'Matt Reeves', 'Director', NULL, NULL),
    (N'Barbie', N'Margot Robbie', 'Actor', N'Barbie', 1),
    (N'Barbie', N'Greta Gerwig', 'Director', NULL, NULL),
    (N'Joker', N'Joaquin Phoenix', 'Actor', N'Arthur Fleck', 1),
    (N'Joker', N'Todd Phillips', 'Director', NULL, NULL),
    (N'Wonka', N'Timothee Chalamet', 'Actor', N'Willy Wonka', 1),
    (N'The Matrix', N'Keanu Reeves', 'Actor', N'Neo', 1),
    (N'The Matrix', N'Lana Wachowski', 'Director', NULL, NULL),
    (N'Inception', N'Leonardo DiCaprio', 'Actor', N'Cobb', 1),
    (N'Inception', N'Christopher Nolan', 'Director', NULL, NULL),
    (N'Harry Potter and the Sorcerer''s Stone', N'Daniel Radcliffe', 'Actor', N'Harry Potter', 1),
    (N'The Dark Knight', N'Christian Bale', 'Actor', N'Bruce Wayne', 1),
    (N'The Dark Knight', N'Christopher Nolan', 'Director', NULL, NULL),
    (N'Mad Max: Fury Road', N'Tom Hardy', 'Actor', N'Max Rockatansky', 1),
    (N'Mad Max: Fury Road', N'Charlize Theron', 'Actor', N'Imperator Furiosa', 2),
    (N'Mad Max: Fury Road', N'George Miller', 'Director', NULL, NULL),
    (N'Civil War', N'Alex Garland', 'Director', NULL, NULL),
    (N'Superman', N'David Corenswet', 'Actor', N'Clark Kent', 1),
    (N'Superman', N'James Gunn', 'Director', NULL, NULL)
) AS v (PrimaryTitle, FullName, CreditRole, CharacterName, BillingOrder)
INNER JOIN cat.Title  AS t ON t.PrimaryTitle = v.PrimaryTitle
INNER JOIN cat.Person AS p ON p.FullName     = v.FullName;

/* English audio + English closed captions for everything, subtitles in the
   languages of the launched markets, dubbing for the more popular titles. */
INSERT INTO cat.TitleLanguageTrack (TitleID, LanguageID, TrackType, IsClosedCaption)
SELECT t.TitleID, l.LanguageID, v.TrackType, v.IsCC
FROM #T AS t
CROSS JOIN (VALUES ('en', 'Audio', 0), ('en', 'Subtitle', 1),
                   ('es', 'Subtitle', 0), ('pt', 'Subtitle', 0), ('fr', 'Subtitle', 0),
                   ('pl', 'Subtitle', 0), ('bg', 'Subtitle', 0), ('nl', 'Subtitle', 0),
                   ('sv', 'Subtitle', 0),
                   ('es', 'Dubbed', 0), ('pt', 'Dubbed', 0), ('fr', 'Dubbed', 0)) AS v (Iso, TrackType, IsCC)
INNER JOIN cat.Language AS l ON l.IsoCode = v.Iso
WHERE v.TrackType <> 'Dubbed' OR t.Pop >= 6 OR t.G1 IN (N'Animation', N'Kids & Family');

/* Licences: every title in every launched market from the later of the
   launch and the catalogue date. Warner-owned studios are 'Owned'; titles of
   third-party studios are licensed, and some of those licences end soon. */
INSERT INTO cat.TitleAvailability (TitleID, CountryID, AvailableFrom, AvailableUntil, LicenseType)
SELECT x.TitleID, x.CountryID, x.AvailableFrom,
       CASE WHEN x.RemovedAt IS NOT NULL THEN x.RemovedAt
            WHEN x.IsOwned = 0 AND dbo.ufn_SeedHash(x.TitleID, x.CountryID, 3) % 4 = 0
                 THEN DATEADD(DAY, dbo.ufn_SeedHash(x.TitleID, x.CountryID, 4) % 150, '2026-10-15') END,
       CASE WHEN x.RemovedAt IS NOT NULL THEN 'Expired'
            WHEN x.IsOwned = 1           THEN 'Owned'
            WHEN dbo.ufn_SeedHash(x.TitleID, x.CountryID, 5) % 3 = 0 THEN 'Exclusive'
            ELSE 'Licensed' END
FROM
(
    SELECT t.TitleID, c.CountryID, t.RemovedAt,
           CASE WHEN t.AddedAt > c.LaunchDate THEN t.AddedAt ELSE c.LaunchDate END AS AvailableFrom,
           CASE WHEN t.IsHbo = 1 OR t.StudioName IN (N'HBO', N'Warner Bros. Pictures', N'Warner Bros. Television',
                                                      N'Warner Bros. Animation', N'DC Studios',
                                                      N'Cartoon Network Studios', N'HBO Documentary Films',
                                                      N'CNN Films')
                THEN 1 ELSE 0 END AS IsOwned
    FROM #T AS t
    CROSS JOIN geo.Country AS c
    WHERE c.IsLaunched = 1
) AS x
WHERE x.RemovedAt IS NULL OR x.AvailableFrom <= x.RemovedAt;

/* =============================================================================
   3. PLANS AND COUPONS
   ============================================================================= */
INSERT INTO acct.[Plan] (PlanCode, PlanName, MonthlyPrice, AnnualPrice, CurrencyCode, MaxConcurrentStreams,
                         MaxVideoQuality, MaxProfiles, AllowsDownloads, HasAdvertising, EffectiveFrom, IsActive)
VALUES ('US_BASIC_ADS',   N'Basic with Ads',        9.99,  99.99, 'USD', 2, 'HD',  3, 0, 1, '2023-05-23', 1),
       ('US_STANDARD',    N'Standard',             16.99, 169.99, 'USD', 2, 'FHD', 5, 1, 0, '2023-05-23', 1),
       ('US_PREMIUM',     N'Premium',              20.99, 209.99, 'USD', 4, '4K',  5, 1, 0, '2023-05-23', 1),
       ('EU_BASIC_ADS',   N'Basic with Ads (EU)',   5.99,   NULL, 'EUR', 2, 'HD',  3, 0, 1, '2022-03-08', 1),
       ('EU_STANDARD',    N'Standard (EU)',         9.99,  99.90, 'EUR', 2, 'FHD', 5, 1, 0, '2022-03-08', 1),
       ('EU_PREMIUM',     N'Premium (EU)',         13.99, 139.90, 'EUR', 4, '4K',  5, 1, 0, '2022-03-08', 1),
       ('LEGACY_AD_FREE', N'Ad-Free (legacy)',     15.99, 149.99, 'USD', 3, '4K',  3, 1, 0, '2020-05-27', 0);

INSERT INTO bill.Coupon (CouponCode, Description, DiscountPercent, DiscountAmount, ValidFrom, ValidTo, MaxRedemptions)
VALUES ('WELCOME50',     N'50% off for new subscribers',              50.00, NULL, '2024-01-01', '2026-12-31', NULL),
       ('BLACKFRIDAY24', N'Black Friday 2024 - 40% off',              40.00, NULL, '2024-11-25', '2024-12-02', 500),
       ('SUMMER25',      N'Summer 2025 - 3.00 off',                   NULL,  3.00, '2025-06-01', '2025-08-31', 1000),
       ('STUDENT30',     N'Student discount - 30% off',               30.00, NULL, '2024-01-01', '2026-12-31', NULL),
       ('LASTOFUS2',     N'The Last of Us season 2 launch - 25% off', 25.00, NULL, '2025-04-01', '2025-05-31', 300),
       ('PENGUIN',       N'The Penguin premiere offer - 2.00 off',    NULL,  2.00, '2024-09-15', '2024-10-31', NULL);

/* =============================================================================
   4. SUBSCRIBERS
   ============================================================================= */
DROP TABLE IF EXISTS #CW;
CREATE TABLE #CW (Iso CHAR(2) PRIMARY KEY, Lo INT, Hi INT, LangIso VARCHAR(5), Dial VARCHAR(4));
INSERT INTO #CW VALUES ('US',  0, 34, 'en', '1'),  ('BR', 35, 44, 'pt', '55'), ('MX', 45, 54, 'es', '52'),
                       ('AR', 55, 59, 'es', '54'), ('CO', 60, 64, 'es', '57'), ('ES', 65, 72, 'es', '34'),
                       ('FR', 73, 79, 'fr', '33'), ('PL', 80, 84, 'pl', '48'), ('NL', 85, 88, 'nl', '31'),
                       ('SE', 89, 91, 'sv', '46'), ('BG', 92, 96, 'bg', '359'), ('PT', 97, 99, 'pt', '351');

DROP TABLE IF EXISTS #FN;
CREATE TABLE #FN (i INT PRIMARY KEY, FirstName NVARCHAR(60), Gender CHAR(1));
INSERT INTO #FN VALUES
 ( 0, N'James', 'M'), ( 1, N'Olivia', 'F'), ( 2, N'Liam', 'M'), ( 3, N'Emma', 'F'), ( 4, N'Noah', 'M'),
 ( 5, N'Ava', 'F'), ( 6, N'Lucas', 'M'), ( 7, N'Sofia', 'F'), ( 8, N'Mateo', 'M'), ( 9, N'Valentina', 'F'),
 (10, N'Gabriel', 'M'), (11, N'Isabella', 'F'), (12, N'Diego', 'M'), (13, N'Camila', 'F'), (14, N'Hugo', 'M'),
 (15, N'Lucia', 'F'), (16, N'Louis', 'M'), (17, N'Chloe', 'F'), (18, N'Jakub', 'M'), (19, N'Zuzanna', 'F'),
 (20, N'Daan', 'M'), (21, N'Julia', 'F'), (22, N'Erik', 'M'), (23, N'Elsa', 'F'), (24, N'Georgi', 'M'),
 (25, N'Maria', 'F'), (26, N'Ivan', 'M'), (27, N'Elena', 'F'), (28, N'Nikolay', 'M'), (29, N'Desislava', 'F'),
 (30, N'Joao', 'M'), (31, N'Beatriz', 'F'), (32, N'Pedro', 'M'), (33, N'Ana', 'F'), (34, N'Daniel', 'M'),
 (35, N'Sara', 'F'), (36, N'Alex', 'X'), (37, N'Sam', 'X'), (38, N'Thomas', 'M'), (39, N'Laura', 'F');

DROP TABLE IF EXISTS #LN;
CREATE TABLE #LN (i INT PRIMARY KEY, LastName NVARCHAR(60));
INSERT INTO #LN VALUES
 ( 0, N'Smith'), ( 1, N'Johnson'), ( 2, N'Williams'), ( 3, N'Brown'), ( 4, N'Garcia'),
 ( 5, N'Martinez'), ( 6, N'Rodriguez'), ( 7, N'Lopez'), ( 8, N'Hernandez'), ( 9, N'Gonzalez'),
 (10, N'Silva'), (11, N'Santos'), (12, N'Oliveira'), (13, N'Pereira'), (14, N'Fernandez'),
 (15, N'Moreno'), (16, N'Dubois'), (17, N'Martin'), (18, N'Bernard'), (19, N'Kowalski'),
 (20, N'Nowak'), (21, N'Wisniewski'), (22, N'de Vries'), (23, N'Jansen'), (24, N'Bakker'),
 (25, N'Andersson'), (26, N'Johansson'), (27, N'Petrov'), (28, N'Ivanov'), (29, N'Georgiev'),
 (30, N'Dimitrova'), (31, N'Popova'), (32, N'Costa'), (33, N'Ferreira'), (34, N'Rossi'),
 (35, N'Miller'), (36, N'Davis'), (37, N'Wilson'), (38, N'Taylor'), (39, N'Clark');

DROP TABLE IF EXISTS #S;
SELECT
    n.n,
    c.CountryID, c.RegionName, c.LaunchDate, l.LanguageID,
    f.FirstName, f.Gender, ln.LastName,
    DATEADD(DAY, dbo.ufn_SeedHash(n.n, 0, 12) % (365 * 43), CAST('1961-01-01' AS DATE)) AS DateOfBirth,
    CAST(NULL AS DATETIME2(0)) AS RegisteredAt,
    cw.Dial,
    CAST(NULL AS INT) AS SubscriberID
INTO #S
FROM #N AS n
INNER JOIN #CW AS cw ON dbo.ufn_SeedHash(n.n, 0, 10) % 100 BETWEEN cw.Lo AND cw.Hi
INNER JOIN geo.Country  AS c  ON c.IsoAlpha2 = cw.Iso
INNER JOIN cat.Language AS l  ON l.IsoCode   = cw.LangIso
INNER JOIN #FN AS f  ON f.i  = dbo.ufn_SeedHash(n.n, 0, 11) % 40
INNER JOIN #LN AS ln ON ln.i = dbo.ufn_SeedHash(n.n, 0, 13) % 40
WHERE n.n <= 600;

/* sign-ups grow over time: sqrt() skews the day offset towards recent dates */
UPDATE #S
   SET RegisteredAt = DATEADD(SECOND, dbo.ufn_SeedHash(n, 0, 15) % 86400,
                      CAST(DATEADD(DAY, CAST(SQRT((dbo.ufn_SeedHash(n, 0, 14) % 10000) / 10000.0) * 993 AS INT),
                                   CAST('2024-01-01' AS DATE)) AS DATETIME2(0)));

UPDATE #S
   SET RegisteredAt = DATEADD(DAY, dbo.ufn_SeedHash(n, 0, 16) % 30, CAST(LaunchDate AS DATETIME2(0)))
 WHERE RegisteredAt < LaunchDate;

INSERT INTO acct.Subscriber
    (Email, PasswordHash, FirstName, LastName, DateOfBirth, Gender, PhoneNumber, CountryID,
     PreferredLanguageID, RegisteredAt, MarketingOptIn, AccountStatus)
SELECT
    LOWER(REPLACE(s.FirstName, N' ', N'') + N'.' + REPLACE(s.LastName, N' ', N'')
          + CAST(s.n AS NVARCHAR(6)) + N'@example.com'),
    HASHBYTES('SHA2_256', CONCAT(N'demo-password-', s.n)),
    s.FirstName, s.LastName, s.DateOfBirth, s.Gender,
    CASE WHEN dbo.ufn_SeedHash(s.n, 0, 17) % 4 = 0 THEN NULL
         ELSE '+' + s.Dial + ' ' + CAST(600000000 + dbo.ufn_SeedHash(s.n, 0, 18) % 99999999 AS VARCHAR(12)) END,
    s.CountryID, s.LanguageID, s.RegisteredAt,
    CASE WHEN dbo.ufn_SeedHash(s.n, 0, 19) % 3 = 0 THEN 1 ELSE 0 END,
    'Active'
FROM #S AS s
ORDER BY s.RegisteredAt, s.n;

UPDATE s SET SubscriberID = sb.SubscriberID
FROM #S AS s
INNER JOIN acct.Subscriber AS sb
        ON sb.Email = LOWER(REPLACE(s.FirstName, N' ', N'') + N'.' + REPLACE(s.LastName, N' ', N'')
                            + CAST(s.n AS NVARCHAR(6)) + N'@example.com');

/* =============================================================================
   5. SUBSCRIPTIONS
   #Sub holds the whole life of each subscription; it is then replayed against
   acct.Subscription in the order things happened, so that the audit trigger
   writes a genuine history (Created -> PlanChange -> trial end ->
   cancellation). After each replay step the audit rows of that step get their
   real historical timestamp.
   ============================================================================= */
DROP TABLE IF EXISTS #Sub;
CREATE TABLE #Sub
(
    SubSeq        INT IDENTITY(1,1) PRIMARY KEY,
    n             INT          NOT NULL,
    Kind          TINYINT      NOT NULL,
    SubscriberID  INT          NOT NULL,
    RegionName    NVARCHAR(30) NOT NULL,
    StartDate     DATE         NOT NULL,
    PlanCode      VARCHAR(20)  NOT NULL,
    BillingCycle  VARCHAR(8)   NOT NULL,
    TrialEndsOn   DATE         NULL,
    ChurnEnd      DATE         NULL,
    CancelledAt   DATETIME2(0) NULL,
    Reason        NVARCHAR(200) NULL,
    TrialOnly     BIT          NOT NULL DEFAULT (0),
    ChangePlanCode VARCHAR(20) NULL,
    ChangeDate    DATE         NULL,
    IsPaused      BIT          NOT NULL DEFAULT (0),
    PlanID        INT          NULL,
    ChangePlanID  INT          NULL,
    SubscriptionID INT         NULL
);

/* first subscription of every subscriber */
INSERT INTO #Sub (n, Kind, SubscriberID, RegionName, StartDate, PlanCode, BillingCycle, TrialEndsOn)
SELECT s.n, 1, s.SubscriberID, s.RegionName, CAST(s.RegisteredAt AS DATE), x.PlanCode,
       CASE WHEN x.PlanCode NOT IN ('EU_BASIC_ADS', 'LEGACY_AD_FREE')
             AND dbo.ufn_SeedHash(s.n, 0, 21) % 100 < 12 THEN 'Annual' ELSE 'Monthly' END,
       CASE WHEN dbo.ufn_SeedHash(s.n, 0, 22) % 100 < 30
            THEN DATEADD(DAY, 7, CAST(s.RegisteredAt AS DATE)) END
FROM #S AS s
CROSS APPLY
(
    SELECT CASE
             WHEN s.RegionName <> N'Europe' AND s.RegisteredAt < '2024-06-01'
                  AND dbo.ufn_SeedHash(s.n, 0, 20) % 4 = 0 THEN 'LEGACY_AD_FREE'
             ELSE CASE WHEN s.RegionName = N'Europe' THEN 'EU_' ELSE 'US_' END
                + CASE WHEN dbo.ufn_SeedHash(s.n, 0, 23) % 100 < 35 THEN 'BASIC_ADS'
                       WHEN dbo.ufn_SeedHash(s.n, 0, 23) % 100 < 75 THEN 'STANDARD'
                       ELSE 'PREMIUM' END
           END AS PlanCode
) AS x
ORDER BY s.RegisteredAt, s.n;

/* churn: a few cancel during the free trial, about a third cancel later */
UPDATE #Sub
   SET TrialOnly   = 1,
       ChurnEnd    = TrialEndsOn,
       CancelledAt = DATEADD(MINUTE, dbo.ufn_SeedHash(n, Kind, 25) % 1440, CAST(DATEADD(DAY, 3, StartDate) AS DATETIME2(0)))
 WHERE TrialEndsOn IS NOT NULL
   AND dbo.ufn_SeedHash(n, Kind, 24) % 100 < 4
   AND TrialEndsOn <= @AsOf;

UPDATE x
   SET ChurnEnd = c.ChurnEnd
  FROM #Sub AS x
  CROSS APPLY
  (
      SELECT DATEADD(DAY, -1,
             CASE WHEN x.BillingCycle = 'Annual'
                  THEN DATEADD(YEAR, 1, ISNULL(x.TrialEndsOn, x.StartDate))
                  ELSE DATEADD(MONTH, 1 + dbo.ufn_SeedHash(x.n, x.Kind, 26) % 14,
                               ISNULL(x.TrialEndsOn, x.StartDate)) END) AS ChurnEnd
  ) AS c
 WHERE x.TrialOnly = 0
   AND dbo.ufn_SeedHash(x.n, x.Kind, 24) % 100 BETWEEN 4 AND 35
   AND c.ChurnEnd <= @AsOf;

UPDATE #Sub
   SET CancelledAt = DATEADD(MINUTE, dbo.ufn_SeedHash(n, Kind, 28) % 1440,
                     CAST(CASE WHEN DATEADD(DAY, -(dbo.ufn_SeedHash(n, Kind, 27) % 20), ChurnEnd) < StartDate
                               THEN StartDate
                               ELSE DATEADD(DAY, -(dbo.ufn_SeedHash(n, Kind, 27) % 20), ChurnEnd) END
                          AS DATETIME2(0)))
 WHERE ChurnEnd IS NOT NULL AND TrialOnly = 0;

UPDATE #Sub
   SET Reason = CASE dbo.ufn_SeedHash(n, Kind, 29) % 6
                     WHEN 0 THEN N'Too expensive'
                     WHEN 1 THEN N'Finished the show I was watching'
                     WHEN 2 THEN N'Switching to another service'
                     WHEN 3 THEN N'Not enough new content'
                     WHEN 4 THEN N'Technical problems with playback'
                     ELSE NULL END
 WHERE ChurnEnd IS NOT NULL;

/* some churned subscribers come back later on a new monthly subscription */
INSERT INTO #Sub (n, Kind, SubscriberID, RegionName, StartDate, PlanCode, BillingCycle)
SELECT x.n, 2, x.SubscriberID, x.RegionName, r.StartDate,
       CASE WHEN x.RegionName = N'Europe' THEN 'EU_' ELSE 'US_' END
     + CASE WHEN dbo.ufn_SeedHash(x.n, 2, 31) % 100 < 40 THEN 'BASIC_ADS'
            WHEN dbo.ufn_SeedHash(x.n, 2, 31) % 100 < 80 THEN 'STANDARD'
            ELSE 'PREMIUM' END,
       'Monthly'
FROM #Sub AS x
CROSS APPLY (SELECT DATEADD(DAY, 30 + dbo.ufn_SeedHash(x.n, 2, 30) % 90, x.ChurnEnd) AS StartDate) AS r
WHERE x.Kind = 1
  AND x.ChurnEnd IS NOT NULL
  AND x.TrialOnly = 0
  AND dbo.ufn_SeedHash(x.n, 2, 32) % 3 = 0
  AND r.StartDate <= DATEADD(DAY, -14, @AsOf);

/* plan changes: the legacy plan is migrated to Standard in summer 2024;
   about 12% of other monthly subscriptions up- or downgrade half-way */
UPDATE #Sub
   SET ChangePlanCode = 'US_STANDARD',
       ChangeDate     = DATEADD(DAY, dbo.ufn_SeedHash(n, Kind, 33) % 30, CAST('2024-07-15' AS DATE))
 WHERE PlanCode = 'LEGACY_AD_FREE'
   AND DATEADD(DAY, dbo.ufn_SeedHash(n, Kind, 33) % 30, CAST('2024-07-15' AS DATE))
       < ISNULL(ChurnEnd, @AsOf);

UPDATE x
   SET ChangePlanCode = LEFT(x.PlanCode, 3) + CASE WHEN x.PlanCode LIKE '%BASIC_ADS' THEN 'STANDARD'
                                                   WHEN x.PlanCode LIKE '%STANDARD'  THEN 'PREMIUM'
                                                   ELSE 'STANDARD' END,
       ChangeDate     = DATEADD(DAY, DATEDIFF(DAY, x.StartDate, ISNULL(x.ChurnEnd, @AsOf)) / 2, x.StartDate)
  FROM #Sub AS x
 WHERE x.PlanCode <> 'LEGACY_AD_FREE'
   AND x.BillingCycle = 'Monthly'
   AND x.TrialOnly = 0
   AND dbo.ufn_SeedHash(x.n, x.Kind, 34) % 100 < 12
   AND DATEDIFF(DAY, x.StartDate, ISNULL(x.ChurnEnd, @AsOf)) >= 60;

UPDATE #Sub
   SET IsPaused = 1
 WHERE ChurnEnd IS NULL
   AND dbo.ufn_SeedHash(n, Kind, 35) % 100 = 99
   AND (TrialEndsOn IS NULL OR TrialEndsOn <= @AsOf);

UPDATE x SET PlanID = p.PlanID
FROM #Sub AS x INNER JOIN acct.[Plan] AS p ON p.PlanCode = x.PlanCode;

UPDATE x SET ChangePlanID = p.PlanID
FROM #Sub AS x INNER JOIN acct.[Plan] AS p ON p.PlanCode = x.ChangePlanCode;

/* replay 1: creation (trigger writes 'Created' at the back-dated StartDate) */
INSERT INTO acct.Subscription
    (SubscriberID, PlanID, StartDate, SubscriptionStatus, BillingCycle, AutoRenew, TrialEndsOn)
SELECT x.SubscriberID, x.PlanID, x.StartDate,
       CASE WHEN x.TrialEndsOn IS NOT NULL THEN 'Trialing' ELSE 'Active' END,
       x.BillingCycle, 1, x.TrialEndsOn
FROM #Sub AS x
ORDER BY x.StartDate, x.SubSeq;

UPDATE x SET SubscriptionID = s.SubscriptionID
FROM #Sub AS x
INNER JOIN acct.Subscription AS s ON s.SubscriberID = x.SubscriberID AND s.StartDate = x.StartDate;

/* replay 2: plan changes */
SELECT @Mark = ISNULL(MAX(ChangeLogID), 0) FROM audit.SubscriptionChangeLog;

UPDATE s SET PlanID = x.ChangePlanID
FROM acct.Subscription AS s
INNER JOIN #Sub AS x ON x.SubscriptionID = s.SubscriptionID
WHERE x.ChangePlanID IS NOT NULL;

UPDATE l
   SET ChangedAt = DATEADD(MINUTE, dbo.ufn_SeedHash(x.n, x.Kind, 36) % 1440, CAST(x.ChangeDate AS DATETIME2(0)))
  FROM audit.SubscriptionChangeLog AS l
  INNER JOIN #Sub AS x ON x.SubscriptionID = l.SubscriptionID
 WHERE l.ChangeLogID > @Mark;

/* replay 3: trials that ended without a cancellation become Active */
SELECT @Mark = ISNULL(MAX(ChangeLogID), 0) FROM audit.SubscriptionChangeLog;

UPDATE s SET SubscriptionStatus = 'Active'
FROM acct.Subscription AS s
INNER JOIN #Sub AS x ON x.SubscriptionID = s.SubscriptionID
WHERE x.TrialEndsOn IS NOT NULL AND x.TrialEndsOn <= @AsOf AND x.TrialOnly = 0;

UPDATE l
   SET ChangedAt = CAST(x.TrialEndsOn AS DATETIME2(0))
  FROM audit.SubscriptionChangeLog AS l
  INNER JOIN #Sub AS x ON x.SubscriptionID = l.SubscriptionID
 WHERE l.ChangeLogID > @Mark;

/* replay 4: cancellations */
SELECT @Mark = ISNULL(MAX(ChangeLogID), 0) FROM audit.SubscriptionChangeLog;

UPDATE s
   SET SubscriptionStatus = 'Cancelled',
       EndDate            = x.ChurnEnd,
       CancelledAt        = x.CancelledAt,
       CancellationReason = x.Reason,
       AutoRenew          = 0
FROM acct.Subscription AS s
INNER JOIN #Sub AS x ON x.SubscriptionID = s.SubscriptionID
WHERE x.ChurnEnd IS NOT NULL;

UPDATE l
   SET ChangedAt = x.CancelledAt
  FROM audit.SubscriptionChangeLog AS l
  INNER JOIN #Sub AS x ON x.SubscriptionID = l.SubscriptionID
 WHERE l.ChangeLogID > @Mark;

/* replay 5: a handful of subscriptions are paused this month */
SELECT @Mark = ISNULL(MAX(ChangeLogID), 0) FROM audit.SubscriptionChangeLog;

UPDATE s SET SubscriptionStatus = 'Paused'
FROM acct.Subscription AS s
INNER JOIN #Sub AS x ON x.SubscriptionID = s.SubscriptionID
WHERE x.IsPaused = 1;

UPDATE l
   SET ChangedAt = CAST(DATEADD(DAY, -(dbo.ufn_SeedHash(x.n, x.Kind, 37) % 25), @AsOf) AS DATETIME2(0))
  FROM audit.SubscriptionChangeLog AS l
  INNER JOIN #Sub AS x ON x.SubscriptionID = l.SubscriptionID
 WHERE l.ChangeLogID > @Mark;

/* =============================================================================
   6. PROFILES, DEVICES, PAYMENT METHODS, COUPONS
   Profiles are created after the subscriptions so that
   acct.trg_Profile_EnforcePlanLimit can check them (at most 3 per subscriber,
   which every plan allows).
   ============================================================================= */
DROP TABLE IF EXISTS #P;
SELECT
    s.SubscriberID, s.n, k.n AS k, s.LanguageID,
    CASE WHEN k.n = 1 THEN s.FirstName
         WHEN k.n = 2 THEN CASE WHEN f2.FirstName = s.FirstName THEN f2.FirstName + N' 2' ELSE f2.FirstName END
         ELSE N'Kids' END AS ProfileName,
    CASE WHEN k.n = 3 THEN 1 ELSE 0 END AS IsKids,
    CASE WHEN DATEADD(DAY, (k.n - 1) * (dbo.ufn_SeedHash(s.n, k.n, 41) % 60), s.RegisteredAt) > @AsOf
         THEN s.RegisteredAt
         ELSE DATEADD(DAY, (k.n - 1) * (dbo.ufn_SeedHash(s.n, k.n, 41) % 60), s.RegisteredAt) END AS CreatedAt
INTO #P
FROM #S AS s
INNER JOIN #N  AS k  ON k.n <= 1 + dbo.ufn_SeedHash(s.n, 0, 40) % 3
INNER JOIN #FN AS f2 ON f2.i = dbo.ufn_SeedHash(s.n, 0, 42) % 40;

INSERT INTO acct.Profile
    (SubscriberID, ProfileName, AvatarUrl, IsKidsProfile, MaturityCeiling, PreferredLanguageID,
     AutoplayNextEpisode, CreatedAt)
SELECT p.SubscriberID, p.ProfileName,
       N'https://img.example.com/avatars/' + CAST(dbo.ufn_SeedHash(p.n, p.k, 43) % 24 + 1 AS NVARCHAR(3)) + N'.png',
       p.IsKids, CASE WHEN p.IsKids = 1 THEN 'TV-Y7' ELSE 'TV-MA' END, p.LanguageID,
       CASE WHEN dbo.ufn_SeedHash(p.n, p.k, 44) % 10 = 0 THEN 0 ELSE 1 END,
       p.CreatedAt
FROM #P AS p
ORDER BY p.CreatedAt, p.SubscriberID, p.k;

/* device catalogue: type, manufacturer, model, operating system */
DROP TABLE IF EXISTS #DevCat;
CREATE TABLE #DevCat (DeviceType VARCHAR(16), Idx INT, Manufacturer NVARCHAR(50), ModelName NVARCHAR(60), OS NVARCHAR(40));
INSERT INTO #DevCat VALUES
 ('SmartTV', 0, N'Samsung', N'QLED Q80C', N'Tizen'),        ('SmartTV', 1, N'LG', N'OLED C3', N'webOS'),
 ('SmartTV', 2, N'Sony', N'Bravia XR A80L', N'Google TV'),  ('SmartTV', 3, N'TCL', N'C745', N'Google TV'),
 ('Mobile', 0, N'Apple', N'iPhone 15', N'iOS'),             ('Mobile', 1, N'Samsung', N'Galaxy S24', N'Android'),
 ('Mobile', 2, N'Google', N'Pixel 8', N'Android'),          ('Mobile', 3, N'Xiaomi', N'Redmi Note 13', N'Android'),
 ('Tablet', 0, N'Apple', N'iPad Air', N'iPadOS'),           ('Tablet', 1, N'Samsung', N'Galaxy Tab S9', N'Android'),
 ('Tablet', 2, N'Lenovo', N'Tab P12', N'Android'),
 ('Laptop', 0, N'Apple', N'MacBook Air', N'macOS'),         ('Laptop', 1, N'Dell', N'XPS 13', N'Windows 11'),
 ('Laptop', 2, N'Lenovo', N'ThinkPad T14', N'Windows 11'),  ('Laptop', 3, N'HP', N'Pavilion 15', N'Windows 11'),
 ('StreamingBox', 0, N'Roku', N'Streaming Stick 4K', N'Roku OS'), ('StreamingBox', 1, N'Amazon', N'Fire TV Stick 4K', N'Fire OS'),
 ('StreamingBox', 2, N'Apple', N'Apple TV 4K', N'tvOS'),    ('StreamingBox', 3, N'Google', N'Chromecast with Google TV', N'Google TV'),
 ('Console', 0, N'Sony', N'PlayStation 5', N'PlayStation OS'), ('Console', 1, N'Microsoft', N'Xbox Series X', N'Xbox OS'),
 ('Browser', 0, N'Google', N'Chrome', N'Windows 11'),       ('Browser', 1, N'Mozilla', N'Firefox', N'Windows 11'),
 ('Browser', 2, N'Apple', N'Safari', N'macOS');

DROP TABLE IF EXISTS #D;
SELECT
    s.SubscriberID, s.n, k.n AS k, s.RegisteredAt, t.DeviceType,
    dc.Manufacturer, dc.ModelName, dc.OS,
    LOWER(CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT('device-', s.n, '-', k.n)), 2)) AS Fingerprint
INTO #D
FROM #S AS s
INNER JOIN #N AS k ON k.n <= 1 + dbo.ufn_SeedHash(s.n, 0, 50) % 3
CROSS APPLY
(
    SELECT CASE WHEN r < 28 THEN 'SmartTV'  WHEN r < 58 THEN 'Mobile'  WHEN r < 68 THEN 'Tablet'
                WHEN r < 80 THEN 'Laptop'   WHEN r < 88 THEN 'StreamingBox'
                WHEN r < 93 THEN 'Console'  ELSE 'Browser' END AS DeviceType
    FROM (SELECT dbo.ufn_SeedHash(s.n, k.n, 51) % 100 AS r) AS q
) AS t
CROSS APPLY (SELECT COUNT(*) AS Cnt FROM #DevCat WHERE DeviceType = t.DeviceType) AS cnt
INNER JOIN #DevCat AS dc ON dc.DeviceType = t.DeviceType
                        AND dc.Idx = dbo.ufn_SeedHash(s.n, k.n, 52) % cnt.Cnt;

INSERT INTO acct.Device
    (SubscriberID, DeviceType, Manufacturer, ModelName, OperatingSystem, AppVersion,
     DeviceFingerprint, RegisteredAt, IsTrusted)
SELECT d.SubscriberID, d.DeviceType, d.Manufacturer, d.ModelName, d.OS,
       CONCAT('4.', dbo.ufn_SeedHash(d.n, d.k, 53) % 12, '.', dbo.ufn_SeedHash(d.n, d.k, 54) % 30),
       d.Fingerprint,
       CASE WHEN DATEADD(DAY, (d.k - 1) * 20, d.RegisteredAt) > @AsOf THEN d.RegisteredAt
            ELSE DATEADD(DAY, (d.k - 1) * 20, d.RegisteredAt) END,
       CASE WHEN d.k = 1 THEN 1 ELSE 0 END
FROM #D AS d
ORDER BY d.RegisteredAt, d.SubscriberID, d.k;

/* payment methods: one each, a second one for ~15% of subscribers */
INSERT INTO bill.PaymentMethod
    (SubscriberID, MethodType, CardBrand, Last4Digits, ExpiryMonth, ExpiryYear,
     BillingCountryID, BillingPostalCode, IsDefault, IsActive, AddedAt)
SELECT s.SubscriberID, m.MethodType,
       CASE WHEN m.MethodType = 'CreditCard' THEN CASE dbo.ufn_SeedHash(s.n, k.n, 61) % 3
                                                       WHEN 0 THEN 'Visa' WHEN 1 THEN 'Mastercard' ELSE 'Amex' END
            WHEN m.MethodType = 'DebitCard'  THEN CASE dbo.ufn_SeedHash(s.n, k.n, 61) % 2
                                                       WHEN 0 THEN 'Visa' ELSE 'Mastercard' END END,
       CASE WHEN m.MethodType IN ('CreditCard', 'DebitCard')
            THEN RIGHT('000' + CAST(dbo.ufn_SeedHash(s.n, k.n, 62) % 10000 AS VARCHAR(4)), 4) END,
       CASE WHEN m.MethodType IN ('CreditCard', 'DebitCard') THEN 1 + dbo.ufn_SeedHash(s.n, k.n, 63) % 12 END,
       CASE WHEN m.MethodType IN ('CreditCard', 'DebitCard') THEN 2027 + dbo.ufn_SeedHash(s.n, k.n, 64) % 4 END,
       s.CountryID,
       CAST(10000 + dbo.ufn_SeedHash(s.n, k.n, 65) % 89999 AS VARCHAR(20)),
       CASE WHEN k.n = 1 THEN 1 ELSE 0 END,
       1,
       CASE WHEN k.n = 1 THEN s.RegisteredAt
            WHEN DATEADD(DAY, 200, s.RegisteredAt) > @AsOf THEN s.RegisteredAt
            ELSE DATEADD(DAY, 200, s.RegisteredAt) END
FROM #S AS s
INNER JOIN #N AS k ON k.n <= CASE WHEN dbo.ufn_SeedHash(s.n, 0, 60) % 100 < 15 THEN 2 ELSE 1 END
CROSS APPLY
(
    SELECT CASE WHEN r < 45 THEN 'CreditCard' WHEN r < 65 THEN 'DebitCard' WHEN r < 80 THEN 'PayPal'
                WHEN r < 88 THEN 'AppleIAP'   WHEN r < 95 THEN 'GoogleIAP' ELSE 'GiftCard' END AS MethodType
    FROM (SELECT dbo.ufn_SeedHash(s.n, k.n, 66) % 100 AS r) AS q
) AS m
ORDER BY s.RegisteredAt, s.SubscriberID, k.n;

/* coupons on ~10% of first subscriptions (trigger checks validity, counts use) */
INSERT INTO bill.SubscriptionCoupon (SubscriptionID, CouponID, AppliedAt)
SELECT x.SubscriptionID, c.CouponID, CAST(x.StartDate AS DATETIME2(0))
FROM #Sub AS x
CROSS APPLY
(
    SELECT TOP (1) cp.CouponID
    FROM bill.Coupon AS cp
    WHERE x.StartDate BETWEEN cp.ValidFrom AND cp.ValidTo
    ORDER BY dbo.ufn_SeedHash(x.SubSeq, cp.CouponID, 71)
) AS c
WHERE x.Kind = 1
  AND dbo.ufn_SeedHash(x.SubSeq, 0, 70) % 100 < 10;

/* =============================================================================
   7. INVOICES AND PAYMENTS
   One invoice per billing period from the end of the trial up to the
   cancellation or @AsOf. The price is the plan in force at the start of the
   period; a coupon discounts the first three invoices while it is valid.
   ============================================================================= */
DROP TABLE IF EXISTS #Inv;
SELECT
    x.SubSeq, x.n, x.Kind, x.SubscriptionID, x.SubscriberID, x.ChurnEnd,
    k.n - 1 AS k,
    pr.PeriodStart,
    DATEADD(DAY, -1, CASE WHEN x.BillingCycle = 'Annual' THEN DATEADD(YEAR, k.n, b.BillStart)
                          ELSE DATEADD(MONTH, k.n, b.BillStart) END) AS PeriodEnd,
    p.PlanID, p.CurrencyCode,
    CAST(CASE WHEN x.BillingCycle = 'Annual' AND p.AnnualPrice IS NOT NULL THEN p.AnnualPrice
              ELSE p.MonthlyPrice END AS DECIMAL(10,2)) AS Subtotal,
    CAST(CASE x.RegionName WHEN N'North America' THEN 8 WHEN N'Latin America' THEN 16 ELSE 20 END
         AS DECIMAL(5,2)) AS TaxRatePct,
    CAST(0 AS DECIMAL(10,2)) AS Discount,
    CAST(NULL AS VARCHAR(20)) AS InvoiceNumber,
    CAST(NULL AS INT) AS InvoiceID
INTO #Inv
FROM #Sub AS x
CROSS APPLY (SELECT ISNULL(x.TrialEndsOn, x.StartDate) AS BillStart) AS b
INNER JOIN #N AS k ON k.n <= 40
CROSS APPLY (SELECT CASE WHEN x.BillingCycle = 'Annual' THEN DATEADD(YEAR, k.n - 1, b.BillStart)
                         ELSE DATEADD(MONTH, k.n - 1, b.BillStart) END AS PeriodStart) AS pr
INNER JOIN acct.[Plan] AS p
        ON p.PlanID = CASE WHEN x.ChangeDate IS NOT NULL AND pr.PeriodStart >= x.ChangeDate
                           THEN x.ChangePlanID ELSE x.PlanID END
WHERE x.TrialOnly = 0
  AND pr.PeriodStart <= @AsOf
  AND (x.ChurnEnd IS NULL OR pr.PeriodStart < x.ChurnEnd);

UPDATE i
   SET Discount = CASE WHEN d.Amount > i.Subtotal THEN i.Subtotal ELSE d.Amount END
  FROM #Inv AS i
  INNER JOIN bill.SubscriptionCoupon AS sc ON sc.SubscriptionID = i.SubscriptionID
  INNER JOIN bill.Coupon AS c ON c.CouponID = sc.CouponID
  CROSS APPLY (SELECT CAST(CASE WHEN c.DiscountPercent IS NOT NULL
                                THEN ROUND(i.Subtotal * c.DiscountPercent / 100.0, 2)
                                ELSE c.DiscountAmount END AS DECIMAL(10,2)) AS Amount) AS d
 WHERE i.k < 3
   AND i.PeriodStart BETWEEN c.ValidFrom AND c.ValidTo;

UPDATE #Inv
   SET InvoiceNumber = 'INV-' + CAST(SubscriptionID AS VARCHAR(7)) + '-' + CONVERT(CHAR(8), PeriodStart, 112);

INSERT INTO bill.Invoice
    (SubscriptionID, InvoiceNumber, IssuedDate, DueDate, PeriodStart, PeriodEnd, SubtotalAmount,
     DiscountAmount, TaxAmount, TotalAmount, CurrencyCode, InvoiceStatus)
SELECT i.SubscriptionID, i.InvoiceNumber, i.PeriodStart, DATEADD(DAY, 7, i.PeriodStart),
       i.PeriodStart, i.PeriodEnd, i.Subtotal, i.Discount, t.Tax,
       i.Subtotal - i.Discount + t.Tax, i.CurrencyCode, 'Open'
FROM #Inv AS i
CROSS APPLY (SELECT CAST(ROUND((i.Subtotal - i.Discount) * i.TaxRatePct / 100.0, 2) AS DECIMAL(10,2)) AS Tax) AS t
ORDER BY i.PeriodStart, i.SubscriptionID;

UPDATE i SET InvoiceID = inv.InvoiceID
FROM #Inv AS i INNER JOIN bill.Invoice AS inv ON inv.InvoiceNumber = i.InvoiceNumber;

/* payment outcome per invoice:
     S  one successful payment          (94.5%)
     FS a failed attempt, then success   (3.5%, and 1% more on older invoices;
                                          the retry is 2 days later, at most @AsOf)
     F  a failed attempt only            (1%, only on the latest invoice of a
                                          live subscription -> PastDue)
     R  paid and later refunded          (1%) */
DROP TABLE IF EXISTS #PayPlan;
SELECT
    i.InvoiceID, i.SubscriberID, i.n, i.k, inv.IssuedDate, inv.TotalAmount, inv.CurrencyCode,
    CASE WHEN r.r < 945 THEN 'S'
         WHEN r.r < 980 THEN 'FS'
         WHEN r.r < 990 THEN CASE WHEN lst.IsLatest = 1 AND i.ChurnEnd IS NULL THEN 'F' ELSE 'FS' END
         ELSE 'R' END AS Outcome
INTO #PayPlan
FROM #Inv AS i
INNER JOIN bill.Invoice AS inv ON inv.InvoiceID = i.InvoiceID
CROSS APPLY (SELECT dbo.ufn_SeedHash(i.InvoiceID, 0, 80) % 1000 AS r) AS r
CROSS APPLY (SELECT CASE WHEN i.PeriodStart = MAX(j.PeriodStart) THEN 1 ELSE 0 END AS IsLatest
             FROM #Inv AS j WHERE j.SubscriptionID = i.SubscriptionID) AS lst;

INSERT INTO bill.Payment
    (InvoiceID, PaymentMethodID, PaidAt, Amount, CurrencyCode, PaymentStatus, GatewayReference, FailureReason)
SELECT pp.InvoiceID, pm.PaymentMethodID, a.PaidAt, pp.TotalAmount, pp.CurrencyCode, a.PaymentStatus,
       'ch_' + LOWER(LEFT(CONVERT(VARCHAR(40), HASHBYTES('MD5', CONCAT('pay-', pp.InvoiceID, '-', a.Attempt)), 2), 24)),
       CASE WHEN a.PaymentStatus = 'Failed'
            THEN CASE dbo.ufn_SeedHash(pp.InvoiceID, a.Attempt, 81) % 3
                      WHEN 0 THEN N'Insufficient funds' WHEN 1 THEN N'Card expired'
                      ELSE N'Do not honor' END END
FROM #PayPlan AS pp
CROSS APPLY
(
    SELECT 1 AS Attempt,
           DATEADD(MINUTE, dbo.ufn_SeedHash(pp.InvoiceID, 1, 82) % 1440, CAST(pp.IssuedDate AS DATETIME2(0))) AS PaidAt,
           CASE pp.Outcome WHEN 'S' THEN 'Succeeded' WHEN 'R' THEN 'Refunded' ELSE 'Failed' END AS PaymentStatus
    UNION ALL
    SELECT 2,
           DATEADD(MINUTE, dbo.ufn_SeedHash(pp.InvoiceID, 2, 82) % 1440,
                   CAST(CASE WHEN DATEADD(DAY, 2, pp.IssuedDate) > @AsOf THEN @AsOf
                             ELSE DATEADD(DAY, 2, pp.IssuedDate) END AS DATETIME2(0))),
           'Succeeded'
    WHERE pp.Outcome = 'FS'
) AS a
CROSS APPLY
(
    SELECT TOP (1) m.PaymentMethodID
    FROM bill.PaymentMethod AS m
    WHERE m.SubscriberID = pp.SubscriberID
      AND m.AddedAt <= DATEADD(DAY, 1, CAST(pp.IssuedDate AS DATETIME2(0)))
    ORDER BY CASE WHEN m.IsDefault = 1 THEN dbo.ufn_SeedHash(pp.InvoiceID, 0, 83) % 3
                  ELSE 1 END,
             m.PaymentMethodID
) AS pm
ORDER BY a.PaidAt, pp.InvoiceID;

/* a live subscription whose latest invoice is unpaid and overdue is PastDue */
SELECT @Mark = ISNULL(MAX(ChangeLogID), 0) FROM audit.SubscriptionChangeLog;

UPDATE s SET SubscriptionStatus = 'PastDue'
FROM acct.Subscription AS s
WHERE s.SubscriptionStatus = 'Active'
  AND EXISTS (SELECT 1 FROM bill.Invoice AS i
               WHERE i.SubscriptionID = s.SubscriptionID AND i.InvoiceStatus = 'Overdue'
                 AND i.PeriodStart = (SELECT MAX(i2.PeriodStart) FROM bill.Invoice AS i2
                                       WHERE i2.SubscriptionID = s.SubscriptionID));

UPDATE l
   SET ChangedAt = CAST(i.DueDate AS DATETIME2(0))
  FROM audit.SubscriptionChangeLog AS l
  INNER JOIN bill.Invoice AS i ON i.SubscriptionID = l.SubscriptionID AND i.InvoiceStatus = 'Overdue'
 WHERE l.ChangeLogID > @Mark;

/* next billing date of every live subscription */
UPDATE s
   SET NextBillingDate = ISNULL(DATEADD(DAY, 1, (SELECT MAX(i.PeriodEnd) FROM bill.Invoice AS i
                                                 WHERE i.SubscriptionID = s.SubscriptionID)),
                                s.TrialEndsOn)
FROM acct.Subscription AS s
WHERE s.SubscriptionStatus NOT IN ('Cancelled', 'Expired');

/* =============================================================================
   8. VIEWING - watch sessions, watchlists, reviews, downloads
   ============================================================================= */

/* popularity-weighted pick lists: all titles, and the kids-safe subset.
   A session of a series is one episode, so series weigh three times as much
   as a film to give them their real share of viewing hours. */
DROP TABLE IF EXISTS #TP;
SELECT t.TitleID, t.TitleType, t.Runtime, t.Imdb, t.Rating,
       SUM(w.W) OVER (ORDER BY t.Seq ROWS UNBOUNDED PRECEDING) - w.W AS Lo,
       SUM(w.W) OVER (ORDER BY t.Seq ROWS UNBOUNDED PRECEDING)       AS Hi
INTO #TP
FROM #T AS t
CROSS APPLY (SELECT t.Pop * CASE WHEN t.TitleType = 'Series' THEN 3 ELSE 1 END AS W) AS w
WHERE t.RemovedAt IS NULL;

DROP TABLE IF EXISTS #TPK;
SELECT t.TitleID, t.TitleType, t.Runtime, t.Imdb, t.Rating,
       SUM(t.Pop) OVER (ORDER BY t.Seq ROWS UNBOUNDED PRECEDING) - t.Pop AS Lo,
       SUM(t.Pop) OVER (ORDER BY t.Seq ROWS UNBOUNDED PRECEDING)         AS Hi
INTO #TPK
FROM #T AS t
WHERE t.RemovedAt IS NULL
  AND t.Rating IN ('TV-Y', 'TV-Y7', 'TV-G', 'G', 'PG', 'TV-PG');

DECLARE @PopAll INT = (SELECT MAX(Hi) FROM #TP), @PopKids INT = (SELECT MAX(Hi) FROM #TPK);

/* episodes in viewing order, per title */
DROP TABLE IF EXISTS #Ep;
SELECT s.TitleID, e.EpisodeID, e.RuntimeMinutes, e.AirDate,
       ROW_NUMBER() OVER (PARTITION BY s.TitleID ORDER BY s.SeasonNumber, e.EpisodeNumber) AS Ord,
       COUNT(*)     OVER (PARTITION BY s.TitleID)                                          AS Cnt
INTO #Ep
FROM cat.Season AS s
INNER JOIN cat.Episode AS e ON e.SeasonID = s.SeasonID;
CREATE UNIQUE CLUSTERED INDEX IX_Ep ON #Ep (TitleID, Ord);

/* the subscriber's devices, numbered */
DROP TABLE IF EXISTS #Dev;
SELECT d.DeviceID, d.SubscriberID, d.DeviceType,
       ROW_NUMBER() OVER (PARTITION BY d.SubscriberID ORDER BY d.DeviceID) AS Ord,
       COUNT(*)     OVER (PARTITION BY d.SubscriberID)                     AS Cnt
INTO #Dev
FROM acct.Device AS d;
CREATE UNIQUE CLUSTERED INDEX IX_Dev ON #Dev (SubscriberID, Ord);

/* hour-of-day weights: evenings dominate */
DROP TABLE IF EXISTS #Hr;
CREATE TABLE #Hr (Hr INT PRIMARY KEY, Lo INT, Hi INT);
INSERT INTO #Hr VALUES
 ( 0, 0, 4), ( 1, 4, 7), ( 2, 7, 8), ( 3, 8, 9), ( 4, 9, 10), ( 5, 10, 11), ( 6, 11, 13), ( 7, 13, 15),
 ( 8, 15, 17), ( 9, 17, 19), (10, 19, 21), (11, 21, 23), (12, 23, 26), (13, 26, 29), (14, 29, 32),
 (15, 32, 35), (16, 35, 38), (17, 38, 42), (18, 42, 50), (19, 50, 60), (20, 60, 71), (21, 71, 81),
 (22, 81, 90), (23, 90, 100);

/* viewing windows: each profile x each subscription of its subscriber */
DROP TABLE IF EXISTS #Win;
SELECT
    ROW_NUMBER() OVER (ORDER BY pr.ProfileID, x.SubSeq) AS WinID,
    pr.ProfileID, pr.SubscriberID, pr.IsKidsProfile, sb.CountryID,
    w.WinStart, w.WinEnd, DATEDIFF(DAY, w.WinStart, w.WinEnd) + 1 AS Days,
    pl.MaxVideoQuality, pl.AllowsDownloads
INTO #Win
FROM acct.Profile AS pr
INNER JOIN acct.Subscriber AS sb ON sb.SubscriberID = pr.SubscriberID
INNER JOIN #Sub AS x ON x.SubscriberID = pr.SubscriberID
INNER JOIN acct.Subscription AS su ON su.SubscriptionID = x.SubscriptionID
INNER JOIN acct.[Plan] AS pl ON pl.PlanID = su.PlanID
CROSS APPLY
(
    SELECT CASE WHEN CAST(pr.CreatedAt AS DATE) > x.StartDate THEN CAST(pr.CreatedAt AS DATE) ELSE x.StartDate END AS WinStart,
           CASE WHEN x.ChurnEnd IS NOT NULL AND x.ChurnEnd < @AsOf THEN x.ChurnEnd ELSE @AsOf END AS WinEnd
) AS w
WHERE w.WinEnd >= w.WinStart;

DROP TABLE IF EXISTS #WS;
CREATE TABLE #WS
(
    ProfileID INT, TitleID INT, EpisodeID INT NULL, EpOrd INT NULL, EpCnt INT NULL, DeviceID INT,
    DeviceType VARCHAR(16), CountryID INT, StartedAt DATETIME2(0), RuntimeMin INT, Pct INT,
    VideoQuality VARCHAR(4), BufferingEvents SMALLINT, Seed BIGINT, AllowsDownloads BIT
);

/* sessions: 3%-15% of the days of a window for adults, 1%-3% for kids */
INSERT INTO #WS
SELECT
    w.ProfileID, tp.TitleID, ep.EpisodeID, ep.Ord, ep.Cnt, dv.DeviceID, dv.DeviceType, w.CountryID,
    st.StartedAt,
    ISNULL(ep.RuntimeMinutes, tp.Runtime),
    CASE WHEN h.h5 % 100 < 55 THEN 95 + h.h6 % 6 ELSE 5 + h.h6 % 86 END,
    CASE WHEN dv.DeviceType = 'Mobile' THEN 'HD'
         WHEN h.h7 % 10 = 0            THEN 'HD'
         ELSE w.MaxVideoQuality END,
    CAST(CASE WHEN h.h8 % 100 < 70 THEN 0 WHEN h.h8 % 100 < 90 THEN 1
              WHEN h.h8 % 100 < 97 THEN 2 ELSE 3 + h.h8 % 4 END
         + CASE WHEN dv.DeviceType = 'Mobile' AND h.h7 % 3 = 0 THEN 1 ELSE 0 END AS SMALLINT),
    CAST(w.WinID AS BIGINT) * 1000 + j.n,
    w.AllowsDownloads
FROM #Win AS w
INNER JOIN #N AS j
        ON j.n <= CASE WHEN w.IsKidsProfile = 1
                       THEN CEILING(w.Days * (1 + dbo.ufn_SeedHash(w.ProfileID, 0, 90) % 3) / 100.0)
                       ELSE CEILING(w.Days * (3 + dbo.ufn_SeedHash(w.ProfileID, 0, 90) % 13) / 100.0) END
CROSS APPLY
(
    SELECT dbo.ufn_SeedHash(w.WinID, j.n, 91) AS h1, dbo.ufn_SeedHash(w.WinID, j.n, 92) AS h2,
           dbo.ufn_SeedHash(w.WinID, j.n, 93) AS h3, dbo.ufn_SeedHash(w.WinID, j.n, 94) AS h4,
           dbo.ufn_SeedHash(w.WinID, j.n, 95) AS h5, dbo.ufn_SeedHash(w.WinID, j.n, 96) AS h6,
           dbo.ufn_SeedHash(w.WinID, j.n, 97) AS h7, dbo.ufn_SeedHash(w.WinID, j.n, 98) AS h8
) AS h
INNER JOIN #Hr AS hr ON h.h2 % 100 >= hr.Lo AND h.h2 % 100 < hr.Hi
CROSS APPLY
(
    SELECT DATEADD(MINUTE, hr.Hr * 60 + h.h3 % 60,
                   CAST(DATEADD(DAY, h.h1 % w.Days, w.WinStart) AS DATETIME2(0))) AS StartedAt
) AS st
CROSS APPLY
(
    SELECT TOP (1) p.TitleID, p.TitleType, p.Runtime
    FROM (SELECT TitleID, TitleType, Runtime, Lo, Hi FROM #TP  WHERE w.IsKidsProfile = 0
          UNION ALL
          SELECT TitleID, TitleType, Runtime, Lo, Hi FROM #TPK WHERE w.IsKidsProfile = 1) AS p
    WHERE h.h4 % CASE WHEN w.IsKidsProfile = 1 THEN @PopKids ELSE @PopAll END >= p.Lo
      AND h.h4 % CASE WHEN w.IsKidsProfile = 1 THEN @PopKids ELSE @PopAll END <  p.Hi
) AS tp
INNER JOIN #Dev AS dv ON dv.SubscriberID = w.SubscriberID AND dv.Ord = 1 + h.h7 % dv.Cnt
LEFT JOIN #Ep AS ep ON ep.TitleID = tp.TitleID
                   AND ep.Ord = 1 + (h.h6 / 7) % ep.Cnt
WHERE (tp.TitleType <> 'Series' OR ep.AirDate <= CAST(st.StartedAt AS DATE))
  AND EXISTS (SELECT 1 FROM cat.TitleAvailability AS ta
               WHERE ta.TitleID = tp.TitleID AND ta.CountryID = w.CountryID
                 AND ta.LicenseType <> 'Expired'
                 AND ta.AvailableFrom <= CAST(st.StartedAt AS DATE)
                 AND (ta.AvailableUntil IS NULL OR ta.AvailableUntil >= CAST(st.StartedAt AS DATE)));

/* binge-watching: a third of finished episodes are followed by the next one */
INSERT INTO #WS
SELECT b.ProfileID, b.TitleID, ep.EpisodeID, ep.Ord, ep.Cnt, b.DeviceID, b.DeviceType, b.CountryID,
       DATEADD(MINUTE, 2, DATEADD(SECOND, b.RuntimeMin * 60 * b.Pct / 100, b.StartedAt)),
       ep.RuntimeMinutes,
       CASE WHEN dbo.ufn_SeedHash(b.Seed, 0, 99) % 100 < 60 THEN 95 + dbo.ufn_SeedHash(b.Seed, 0, 100) % 6
            ELSE 10 + dbo.ufn_SeedHash(b.Seed, 0, 100) % 80 END,
       b.VideoQuality, 0, b.Seed * 10 + 1, b.AllowsDownloads
FROM #WS AS b
INNER JOIN #Ep AS ep ON ep.TitleID = b.TitleID AND ep.Ord = b.EpOrd + 1
WHERE b.EpisodeID IS NOT NULL
  AND b.Pct >= 95
  AND dbo.ufn_SeedHash(b.Seed, 0, 101) % 3 = 0
  AND ep.AirDate <= CAST(b.StartedAt AS DATE)
  AND DATEADD(MINUTE, 2, DATEADD(SECOND, b.RuntimeMin * 60 * b.Pct / 100, b.StartedAt)) < @AsOfEnd;

INSERT INTO play.WatchSession
    (ProfileID, TitleID, EpisodeID, DeviceID, CountryID, StartedAt, EndedAt, SecondsWatched,
     PercentComplete, VideoQuality, IsCompleted, BufferingEvents)
SELECT s.ProfileID, s.TitleID, s.EpisodeID, s.DeviceID, s.CountryID, s.StartedAt,
       DATEADD(SECOND, s.RuntimeMin * 60 * s.Pct / 100, s.StartedAt),
       s.RuntimeMin * 60 * s.Pct / 100,
       s.Pct, s.VideoQuality,
       CASE WHEN s.Pct >= 90 THEN 1 ELSE 0 END,
       s.BufferingEvents
FROM #WS AS s
ORDER BY s.StartedAt, s.ProfileID;

/* watchlists: up to 5 titles per profile */
INSERT INTO play.Watchlist (ProfileID, TitleID, AddedAt, SortPriority)
SELECT q.ProfileID, q.TitleID, MIN(q.AddedAt),
       ROW_NUMBER() OVER (PARTITION BY q.ProfileID ORDER BY MIN(q.AddedAt))
FROM
(
    SELECT pr.ProfileID, tp.TitleID,
           CASE WHEN DATEADD(DAY, dbo.ufn_SeedHash(pr.ProfileID, j.n, 111) % 300, pr.CreatedAt) > @AsOf
                THEN pr.CreatedAt
                ELSE DATEADD(DAY, dbo.ufn_SeedHash(pr.ProfileID, j.n, 111) % 300, pr.CreatedAt) END AS AddedAt
    FROM acct.Profile AS pr
    INNER JOIN #N AS j ON j.n <= dbo.ufn_SeedHash(pr.ProfileID, 0, 110) % 6
    INNER JOIN #TP AS tp ON dbo.ufn_SeedHash(pr.ProfileID, j.n, 112) % @PopAll >= tp.Lo
                        AND dbo.ufn_SeedHash(pr.ProfileID, j.n, 112) % @PopAll <  tp.Hi
    WHERE pr.IsKidsProfile = 0
) AS q
GROUP BY q.ProfileID, q.TitleID;

/* reviews: ~12% of watched profile/title pairs (4% for kids profiles) */
DROP TABLE IF EXISTS #RT;
CREATE TABLE #RT (Band CHAR(1), i INT, ReviewTitle NVARCHAR(150), ReviewText NVARCHAR(2000));
INSERT INTO #RT VALUES
 ('H', 0, N'Absolutely brilliant', N'One of the best things I have watched in years. The writing and the acting are outstanding.'),
 ('H', 1, N'Worth every minute', N'Gripping from start to finish. I could not stop watching.'),
 ('H', 2, N'A masterpiece', N'Beautifully shot, brilliantly acted, and it stays with you long after it ends.'),
 ('M', 0, N'Good, not great', N'Enjoyable overall, but the middle part drags a little.'),
 ('M', 1, N'Decent watch', N'Some strong moments and a few weak ones. Fine for a quiet evening.'),
 ('M', 2, N'Mixed feelings', N'Great cast, but the story did not fully work for me.'),
 ('L', 0, N'Disappointing', N'I expected much more. Slow and predictable.'),
 ('L', 1, N'Not for me', N'I gave up halfway through. Could not connect with any of the characters.'),
 ('L', 2, N'Overhyped', N'All the buzz made me watch it, but it was a let-down.');

INSERT INTO play.Review
    (ProfileID, TitleID, RatingValue, ReviewTitle, ReviewText, CreatedAt, UpdatedAt, HelpfulVotes, IsFlagged)
SELECT r.ProfileID, r.TitleID, r.Rating,
       CASE WHEN r.HasText = 1 THEN rt.ReviewTitle END,
       CASE WHEN r.HasText = 1 THEN rt.ReviewText END,
       r.CreatedAt,
       CASE WHEN dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 124) % 100 < 8
             AND DATEADD(DAY, 10 + dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 125) % 50, r.CreatedAt) <= @AsOf
            THEN DATEADD(DAY, 10 + dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 125) % 50, r.CreatedAt) END,
       CASE WHEN dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 126) % 100 < 50 THEN 0
            ELSE dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 127) % 120 END,
       CASE WHEN dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 128) % 250 = 0 THEN 1 ELSE 0 END
FROM
(
    SELECT f.ProfileID, f.TitleID,
           CASE WHEN f.Base < 1 THEN 1 WHEN f.Base > 10 THEN 10 ELSE f.Base END AS Rating,
           CASE WHEN DATEADD(HOUR, 1 + dbo.ufn_SeedHash(f.ProfileID, f.TitleID, 121) % 72, f.FirstWatch)
                     > DATEADD(DAY, 1, CAST(@AsOf AS DATETIME2(0)))
                THEN DATEADD(HOUR, 1, f.FirstWatch)
                ELSE DATEADD(HOUR, 1 + dbo.ufn_SeedHash(f.ProfileID, f.TitleID, 121) % 72, f.FirstWatch) END AS CreatedAt,
           CASE WHEN dbo.ufn_SeedHash(f.ProfileID, f.TitleID, 122) % 100 < 45 THEN 1 ELSE 0 END AS HasText
    FROM
    (
        SELECT ws.ProfileID, ws.TitleID, MIN(ws.EndedAt) AS FirstWatch,
               CAST(ROUND(ISNULL(MAX(t.ImdbRating), 7), 0) AS INT)
               + dbo.ufn_SeedHash(ws.ProfileID, ws.TitleID, 120) % 5 - 2 AS Base,
               MAX(CAST(pr.IsKidsProfile AS INT)) AS IsKids
        FROM play.WatchSession AS ws
        INNER JOIN cat.Title    AS t  ON t.TitleID   = ws.TitleID
        INNER JOIN acct.Profile AS pr ON pr.ProfileID = ws.ProfileID
        GROUP BY ws.ProfileID, ws.TitleID
    ) AS f
    WHERE dbo.ufn_SeedHash(f.ProfileID, f.TitleID, 123) % 100 < CASE WHEN f.IsKids = 1 THEN 4 ELSE 12 END
) AS r
INNER JOIN #RT AS rt
        ON rt.Band = CASE WHEN r.Rating >= 8 THEN 'H' WHEN r.Rating >= 5 THEN 'M' ELSE 'L' END
       AND rt.i    = dbo.ufn_SeedHash(r.ProfileID, r.TitleID, 129) % 3
ORDER BY r.CreatedAt;

/* downloads: some mobile/tablet sessions on plans that allow downloads */
INSERT INTO play.Download
    (ProfileID, DeviceID, TitleID, EpisodeID, DownloadedAt, ExpiresAt, FileSizeMb, DownloadStatus)
SELECT d.ProfileID, d.DeviceID, d.TitleID, d.EpisodeID, d.DownloadedAt, DATEADD(DAY, 30, d.DownloadedAt),
       CAST(d.RuntimeMin * CASE d.VideoQuality WHEN 'SD' THEN 7 WHEN 'HD' THEN 15 WHEN 'FHD' THEN 25 ELSE 45 END
            AS DECIMAL(10,2)),
       CASE WHEN dbo.ufn_SeedHash(d.Seed, 0, 131) % 25 = 0 THEN 'Failed'
            WHEN DATEADD(DAY, 30, d.DownloadedAt) < @AsOf THEN
                 CASE WHEN dbo.ufn_SeedHash(d.Seed, 0, 132) % 3 = 0 THEN 'Deleted' ELSE 'Expired' END
            ELSE 'Completed' END
FROM
(
    SELECT s.*, DATEADD(HOUR, -(1 + dbo.ufn_SeedHash(s.Seed, 0, 130) % 48), s.StartedAt) AS DownloadedAt
    FROM #WS AS s
    WHERE s.DeviceType IN ('Mobile', 'Tablet')
      AND s.AllowsDownloads = 1
      AND dbo.ufn_SeedHash(s.Seed, 0, 133) % 6 = 0
) AS d
ORDER BY d.DownloadedAt;

/* =============================================================================
   9. LAST-SEEN / LAST-LOGIN AND ACCOUNT STATUS
   ============================================================================= */
UPDATE d
   SET LastSeenAt = x.LastSeen
  FROM acct.Device AS d
  INNER JOIN (SELECT DeviceID, MAX(EndedAt) AS LastSeen FROM play.WatchSession GROUP BY DeviceID) AS x
          ON x.DeviceID = d.DeviceID;

UPDATE sb
   SET LastLoginAt = ISNULL(x.LastSeen, DATEADD(HOUR, 1, sb.RegisteredAt))
  FROM acct.Subscriber AS sb
  LEFT JOIN (SELECT pr.SubscriberID, MAX(ws.StartedAt) AS LastSeen
               FROM play.WatchSession AS ws
               INNER JOIN acct.Profile AS pr ON pr.ProfileID = ws.ProfileID
              GROUP BY pr.SubscriberID) AS x
         ON x.SubscriberID = sb.SubscriberID;

/* half of the subscribers without a live subscription closed their account */
UPDATE sb
   SET AccountStatus = 'Closed'
  FROM acct.Subscriber AS sb
 WHERE NOT EXISTS (SELECT 1 FROM acct.Subscription AS s
                    WHERE s.SubscriberID = sb.SubscriberID
                      AND s.SubscriptionStatus NOT IN ('Cancelled', 'Expired'))
   AND sb.SubscriberID % 2 = 0;

COMMIT TRANSACTION;
GO

DROP FUNCTION IF EXISTS dbo.ufn_SeedHash;
GO

/* =============================================================================
   SUMMARY
   ============================================================================= */
SELECT 'geo.Country' AS TableName, COUNT(*) AS RowCnt FROM geo.Country
UNION ALL SELECT 'cat.Language',            COUNT(*) FROM cat.Language
UNION ALL SELECT 'cat.Genre',               COUNT(*) FROM cat.Genre
UNION ALL SELECT 'cat.Studio',              COUNT(*) FROM cat.Studio
UNION ALL SELECT 'cat.Person',              COUNT(*) FROM cat.Person
UNION ALL SELECT 'cat.Title',               COUNT(*) FROM cat.Title
UNION ALL SELECT 'cat.Season',              COUNT(*) FROM cat.Season
UNION ALL SELECT 'cat.Episode',             COUNT(*) FROM cat.Episode
UNION ALL SELECT 'cat.TitleGenre',          COUNT(*) FROM cat.TitleGenre
UNION ALL SELECT 'cat.Credit',              COUNT(*) FROM cat.Credit
UNION ALL SELECT 'cat.TitleLanguageTrack',  COUNT(*) FROM cat.TitleLanguageTrack
UNION ALL SELECT 'cat.TitleAvailability',   COUNT(*) FROM cat.TitleAvailability
UNION ALL SELECT 'acct.Plan',                 COUNT(*) FROM acct.[Plan]
UNION ALL SELECT 'acct.Subscriber',         COUNT(*) FROM acct.Subscriber
UNION ALL SELECT 'acct.Subscription',       COUNT(*) FROM acct.Subscription
UNION ALL SELECT 'acct.Profile',            COUNT(*) FROM acct.Profile
UNION ALL SELECT 'acct.Device',             COUNT(*) FROM acct.Device
UNION ALL SELECT 'audit.SubscriptionChangeLog', COUNT(*) FROM audit.SubscriptionChangeLog
UNION ALL SELECT 'play.WatchSession',       COUNT(*) FROM play.WatchSession
UNION ALL SELECT 'play.Watchlist',          COUNT(*) FROM play.Watchlist
UNION ALL SELECT 'play.Review',             COUNT(*) FROM play.Review
UNION ALL SELECT 'play.Download',           COUNT(*) FROM play.Download
UNION ALL SELECT 'bill.PaymentMethod',      COUNT(*) FROM bill.PaymentMethod
UNION ALL SELECT 'bill.Coupon',             COUNT(*) FROM bill.Coupon
UNION ALL SELECT 'bill.SubscriptionCoupon', COUNT(*) FROM bill.SubscriptionCoupon
UNION ALL SELECT 'bill.Invoice',            COUNT(*) FROM bill.Invoice
UNION ALL SELECT 'bill.Payment',            COUNT(*) FROM bill.Payment;
GO

PRINT '08_seed_data.sql: HBOMaxOLTP populated.';
GO
