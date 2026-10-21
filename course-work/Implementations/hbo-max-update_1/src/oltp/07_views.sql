/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    07_views.sql
   Purpose: 4 operational views over the OLTP model.
   Target:  Microsoft SQL Server 2019+
   Depends: 02_tables.sql and 04_functions.sql must have run first.

   View                            Question it answers
   ------------------------------  -------------------------------------------
   acct.vw_ActiveSubscriptions     who is subscribed right now, on which plan
   cat.vw_TitleCatalog             the catalogue with its denormalised facts
   play.vw_ProfileViewingSummary   how much each profile watches
   bill.vw_OutstandingInvoices     which invoices still have money owed

   These are the OLTP-side views for the application and support staff. The
   analytical views for the report live in the warehouse
   (src/dw/15_dw_analytic_views.sql).
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* =============================================================================
   acct.vw_ActiveSubscriptions
   One row per subscription that has not ended and is not Cancelled / Expired.
   ============================================================================= */
CREATE OR ALTER VIEW acct.vw_ActiveSubscriptions
AS
SELECT
    s.SubscriptionID,
    sb.SubscriberID,
    sb.FirstName + N' ' + sb.LastName                         AS SubscriberName,
    sb.Email,
    acct.ufn_GetAge(sb.DateOfBirth, CAST(SYSUTCDATETIME() AS DATE)) AS SubscriberAge,
    c.CountryName,
    c.RegionName,
    p.PlanCode,
    p.PlanName,
    s.BillingCycle,
    CASE WHEN s.BillingCycle = 'Annual' AND p.AnnualPrice IS NOT NULL
         THEN p.AnnualPrice ELSE p.MonthlyPrice END            AS PeriodPrice,
    p.CurrencyCode,
    s.SubscriptionStatus,
    s.StartDate,
    s.TrialEndsOn,
    s.NextBillingDate,
    s.AutoRenew,
    DATEDIFF(MONTH, s.StartDate, CAST(SYSUTCDATETIME() AS DATE)) AS TenureMonths,
    (SELECT COUNT(*) FROM acct.Profile AS pr WHERE pr.SubscriberID = sb.SubscriberID) AS ProfileCount,
    p.MaxProfiles
FROM acct.Subscription AS s
INNER JOIN acct.Subscriber AS sb ON sb.SubscriberID = s.SubscriberID
INNER JOIN geo.Country     AS c  ON c.CountryID     = sb.CountryID
INNER JOIN acct.[Plan]     AS p  ON p.PlanID        = s.PlanID
WHERE s.SubscriptionStatus NOT IN ('Cancelled', 'Expired')
  AND (s.EndDate IS NULL OR s.EndDate >= CAST(SYSUTCDATETIME() AS DATE));
GO

/* =============================================================================
   cat.vw_TitleCatalog
   One row per title with its primary genre, studio, language, size and rating.
   ============================================================================= */
CREATE OR ALTER VIEW cat.vw_TitleCatalog
AS
SELECT
    t.TitleID,
    t.PrimaryTitle,
    t.TitleType,
    t.ReleaseYear,
    t.MaturityRating,
    pg.GenreName                                AS PrimaryGenre,
    st.StudioName,
    l.LanguageName                              AS OriginalLanguage,
    CASE WHEN t.IsHboOriginal = 1 THEN 'HBO Original' ELSE 'Licensed' END AS ContentSource,
    (SELECT COUNT(*) FROM cat.Season AS s WHERE s.TitleID = t.TitleID)     AS SeasonCount,
    (SELECT COUNT(*) FROM cat.Season AS s
       INNER JOIN cat.Episode AS e ON e.SeasonID = s.SeasonID
      WHERE s.TitleID = t.TitleID)                                          AS EpisodeCount,
    cat.ufn_GetTitleTotalRuntime(t.TitleID)                                 AS TotalRuntimeMinutes,
    t.ImdbRating,
    t.AverageUserRating,
    t.UserRatingCount,
    (SELECT COUNT(*) FROM cat.TitleAvailability AS ta
      WHERE ta.TitleID = t.TitleID
        AND ta.LicenseType <> 'Expired'
        AND ta.AvailableFrom <= CAST(SYSUTCDATETIME() AS DATE)
        AND (ta.AvailableUntil IS NULL OR ta.AvailableUntil >= CAST(SYSUTCDATETIME() AS DATE))
    )                                                                       AS AvailableInCountries,
    CAST(CASE WHEN t.RemovedFromCatalogAt IS NULL THEN 1 ELSE 0 END AS BIT) AS IsInCatalog
FROM cat.Title AS t
INNER JOIN cat.Language AS l  ON l.LanguageID = t.OriginalLanguageID
LEFT  JOIN cat.Studio   AS st ON st.StudioID  = t.StudioID
OUTER APPLY
(
    SELECT TOP (1) g.GenreName
    FROM cat.TitleGenre AS tg
    INNER JOIN cat.Genre AS g ON g.GenreID = tg.GenreID
    WHERE tg.TitleID = t.TitleID
    ORDER BY tg.IsPrimaryGenre DESC, g.GenreName
) AS pg;
GO

/* =============================================================================
   play.vw_ProfileViewingSummary
   One row per profile: sessions, hours, distinct titles, completion rate.
   Profiles that never watched anything are included with zeros.
   ============================================================================= */
CREATE OR ALTER VIEW play.vw_ProfileViewingSummary
AS
SELECT
    pr.ProfileID,
    pr.ProfileName,
    pr.IsKidsProfile,
    sb.SubscriberID,
    sb.Email,
    ISNULL(v.SessionCount, 0)                                   AS SessionCount,
    CAST(ISNULL(v.SecondsWatched, 0) / 3600.0 AS DECIMAL(12,2)) AS HoursWatched,
    ISNULL(v.DistinctTitles, 0)                                 AS DistinctTitles,
    CAST(CASE WHEN ISNULL(v.SessionCount, 0) = 0 THEN 0
              ELSE 100.0 * v.CompletedCount / v.SessionCount END AS DECIMAL(5,2)) AS CompletionRatePct,
    v.LastWatchedAt
FROM acct.Profile AS pr
INNER JOIN acct.Subscriber AS sb ON sb.SubscriberID = pr.SubscriberID
LEFT JOIN
(
    SELECT
        ws.ProfileID,
        COUNT(*)                                        AS SessionCount,
        SUM(CAST(ws.SecondsWatched AS BIGINT))          AS SecondsWatched,
        COUNT(DISTINCT ws.TitleID)                      AS DistinctTitles,
        SUM(CASE WHEN ws.IsCompleted = 1 THEN 1 ELSE 0 END) AS CompletedCount,
        MAX(ws.StartedAt)                               AS LastWatchedAt
    FROM play.WatchSession AS ws
    GROUP BY ws.ProfileID
) AS v ON v.ProfileID = pr.ProfileID;
GO

/* =============================================================================
   bill.vw_OutstandingInvoices
   Invoices that still have a positive balance, with how overdue they are.
   ============================================================================= */
CREATE OR ALTER VIEW bill.vw_OutstandingInvoices
AS
SELECT
    i.InvoiceID,
    i.InvoiceNumber,
    i.SubscriptionID,
    sb.SubscriberID,
    sb.Email,
    i.IssuedDate,
    i.DueDate,
    i.TotalAmount,
    bill.ufn_GetInvoiceBalance(i.InvoiceID)                     AS BalanceDue,
    i.CurrencyCode,
    i.InvoiceStatus,
    CASE WHEN i.DueDate < CAST(SYSUTCDATETIME() AS DATE)
         THEN DATEDIFF(DAY, i.DueDate, CAST(SYSUTCDATETIME() AS DATE))
         ELSE 0 END                                             AS DaysOverdue
FROM bill.Invoice AS i
INNER JOIN acct.Subscription AS s  ON s.SubscriptionID = i.SubscriptionID
INNER JOIN acct.Subscriber   AS sb ON sb.SubscriberID  = s.SubscriberID
WHERE i.InvoiceStatus IN ('Open', 'PartiallyPaid', 'Overdue');
GO

PRINT 'HBOMaxOLTP: 4 views created.';
GO
