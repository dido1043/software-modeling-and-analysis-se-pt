/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    15_dw_analytic_views.sql
   Purpose: 7 analytic views - one per business question, each shaped for the
            Power BI visual that consumes it (docs/POWER_BI_REPORT.md).
   Target:  Microsoft SQL Server 2019+
   Depends: 11, 12 (and, for data, 14 + a load) must have run first.

   Rules followed by every view
     - Rows attached to a -1 Unknown member are EXCLUDED from the grouping
       they would distort (they are reported by 16_run_full_load.sql instead).
     - People are counted by natural key (COUNT DISTINCT SubscriberID /
       ProfileKey), never by SCD Type 2 surrogate key, so a subscriber with two
       versions is still one person.
     - Non-additive measures (percentages, averages, ratings) are computed in
       the view as ratios of sums, so Power BI can show them without DAX.
     - Semi-additive snapshot measures (MRR, active subscriptions) are only
       aggregated WITHIN a single month.
     - Money is never summed across currencies: every revenue row carries its
       CurrencyCode (USD plans and EUR plans are separate plans).
   The views are not schema-bound: they use COUNT(DISTINCT), window functions
   and outer joins, which indexed views cannot contain.
   ============================================================================= */

USE HBOMaxDW;
GO

/* =============================================================================
   dw.vw_ViewingTrendByMonthRegion
   Question   : how is viewing demand changing, by region?
   Grain      : month x region
   CONSUMED BY: Page 1 - cards (hours, sessions, binge sessions) and the
                "Hours watched by month and region" line chart.
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_ViewingTrendByMonthRegion
AS
SELECT
    d.MonthKey,
    MAX(d.MonthYearLabel)                                         AS MonthLabel,
    MAX(d.YearNumber)                                             AS CalendarYear,
    g.RegionName,
    CAST(SUM(f.HoursWatched) AS DECIMAL(14,2))                    AS HoursWatched,
    SUM(CAST(f.SessionCount AS INT))                              AS SessionCount,
    SUM(CAST(f.IsBingeSession AS INT))                            AS BingeSessionCount,
    COUNT(DISTINCT s.SubscriberID)                                AS ActiveViewers,
    CAST(AVG(f.PercentComplete) AS DECIMAL(5,2))                  AS AvgCompletionPct
FROM dw.FactViewingSession AS f
INNER JOIN dw.DimDate       AS d ON d.DateKey       = f.DateKey
INNER JOIN dw.DimGeography  AS g ON g.GeographyKey  = f.GeographyKey
INNER JOIN dw.DimSubscriber AS s ON s.SubscriberKey = f.SubscriberKey
WHERE f.DateKey <> -1
  AND f.GeographyKey <> -1
GROUP BY d.MonthKey, g.RegionName;
GO

/* =============================================================================
   dw.vw_TopTitlesByHoursWatched
   Question   : which titles drive viewing, and are they finished and liked?
   Grain      : title
   CONSUMED BY: Page 2 - "Top 20 titles" bar chart and the title detail table
                (filter HoursRank <= 20).
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_TopTitlesByHoursWatched
AS
WITH Viewing AS
(
    SELECT
        f.TitleKey,
        SUM(f.HoursWatched)                    AS HoursWatched,
        SUM(CAST(f.SessionCount AS INT))       AS SessionCount,
        SUM(CAST(f.IsCompletedFlag AS INT))    AS CompletedSessions,
        COUNT(DISTINCT f.ProfileKey)           AS UniqueViewers
    FROM dw.FactViewingSession AS f
    WHERE f.TitleKey <> -1
    GROUP BY f.TitleKey
),
Ratings AS
(
    SELECT r.TitleKey,
           AVG(CAST(r.RatingValue AS DECIMAL(6,2))) AS AvgRating,
           SUM(CAST(r.ReviewCount AS INT))          AS ReviewCount
    FROM dw.FactTitleRating AS r
    WHERE r.TitleKey <> -1
    GROUP BY r.TitleKey
)
SELECT
    t.TitleKey,
    t.TitleID,
    t.PrimaryTitle                                                      AS TitleName,
    t.TitleType,
    t.PrimaryGenreName                                                  AS PrimaryGenre,
    t.ContentSource,
    t.ReleaseYear,
    CAST(v.HoursWatched AS DECIMAL(14,2))                               AS HoursWatched,
    v.SessionCount,
    v.UniqueViewers,
    CAST(100.0 * v.CompletedSessions / NULLIF(v.SessionCount, 0) AS DECIMAL(5,2)) AS CompletionRatePct,
    CAST(r.AvgRating AS DECIMAL(4,2))                                   AS AvgRating,
    ISNULL(r.ReviewCount, 0)                                            AS ReviewCount,
    RANK() OVER (ORDER BY v.HoursWatched DESC)                          AS HoursRank
FROM Viewing AS v
INNER JOIN dw.DimTitle AS t ON t.TitleKey = v.TitleKey
LEFT  JOIN Ratings     AS r ON r.TitleKey = v.TitleKey;
GO

/* =============================================================================
   dw.vw_RevenueAndMrrByPlan
   Question   : how do revenue, MRR and ARPU split by plan over time?
   Grain      : month x plan
   Revenue    : cash basis - net revenue (paid - refunded) of the payments made
                in the month, from FactRevenue.
   MRR        : from the month-end subscription snapshot (alive, non-trial,
                non-paused subscriptions at the plan price in force).
   CONSUMED BY: Page 3 - "Recognised revenue and MRR by month" combo chart,
                "ARPU by plan by month" matrix, payment failure rate card.
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_RevenueAndMrrByPlan
AS
WITH Rev AS
(
    SELECT
        d.MonthKey,
        p.PlanID,
        SUM(f.NetRevenueAmount)                 AS RecognisedRevenue,
        SUM(f.DiscountAmount)                   AS DiscountAmount,
        SUM(f.TaxAmount)                        AS TaxAmount,
        SUM(CAST(f.PaymentCount AS INT))        AS PaymentCount,
        SUM(CAST(f.FailedPaymentCount AS INT))  AS FailedPaymentCount
    FROM dw.FactRevenue AS f
    INNER JOIN dw.DimDate AS d ON d.DateKey = f.PaymentDateKey
    INNER JOIN dw.DimPlan AS p ON p.PlanKey = f.PlanKey
    WHERE f.PaymentDateKey <> -1
      AND f.PlanKey <> -1
    GROUP BY d.MonthKey, p.PlanID
),
Mrr AS
(
    SELECT
        s.SnapshotMonthKey                       AS MonthKey,
        p.PlanID,
        SUM(s.MonthlyRecurringRevenue)           AS Mrr,
        SUM(CAST(s.ActiveSubscriptionCount AS INT)) AS ActiveSubscriptions,
        SUM(CAST(s.IsNewThisMonth AS INT))       AS NewSubscriptions,
        SUM(CAST(s.IsChurnedThisMonth AS INT))   AS ChurnedSubscriptions
    FROM dw.FactSubscriptionMonthlySnapshot AS s
    INNER JOIN dw.DimPlan AS p ON p.PlanKey = s.PlanKey
    WHERE s.PlanKey <> -1
    GROUP BY s.SnapshotMonthKey, p.PlanID
),
Combined AS
(
    SELECT
        COALESCE(r.MonthKey, m.MonthKey) AS MonthKey,
        COALESCE(r.PlanID,   m.PlanID)   AS PlanID,
        ISNULL(r.RecognisedRevenue, 0)   AS RecognisedRevenue,
        ISNULL(r.DiscountAmount, 0)      AS DiscountAmount,
        ISNULL(r.TaxAmount, 0)           AS TaxAmount,
        ISNULL(r.PaymentCount, 0)        AS PaymentCount,
        ISNULL(r.FailedPaymentCount, 0)  AS FailedPaymentCount,
        ISNULL(m.Mrr, 0)                 AS Mrr,
        ISNULL(m.ActiveSubscriptions, 0) AS ActiveSubscriptions,
        ISNULL(m.NewSubscriptions, 0)    AS NewSubscriptions,
        ISNULL(m.ChurnedSubscriptions, 0) AS ChurnedSubscriptions
    FROM Rev AS r
    FULL OUTER JOIN Mrr AS m ON m.MonthKey = r.MonthKey AND m.PlanID = r.PlanID
)
SELECT
    c.MonthKey,
    dm.MonthYearLabel                                                       AS MonthLabel,
    dm.YearNumber                                                           AS CalendarYear,
    c.PlanID,
    cp.PlanCode,
    cp.PlanName,
    cp.CurrencyCode,
    CAST(c.RecognisedRevenue AS DECIMAL(14,2))                              AS RecognisedRevenue,
    CAST(c.DiscountAmount AS DECIMAL(14,2))                                 AS DiscountAmount,
    CAST(c.TaxAmount AS DECIMAL(14,2))                                      AS TaxAmount,
    CAST(c.Mrr AS DECIMAL(14,2))                                            AS Mrr,
    c.ActiveSubscriptions,
    c.NewSubscriptions,
    c.ChurnedSubscriptions,
    CAST(c.RecognisedRevenue / NULLIF(c.ActiveSubscriptions, 0) AS DECIMAL(10,2)) AS ArpuRecognised,
    c.PaymentCount,
    c.FailedPaymentCount,
    CAST(100.0 * c.FailedPaymentCount / NULLIF(c.PaymentCount, 0) AS DECIMAL(5,2)) AS PaymentFailureRatePct
FROM Combined AS c
INNER JOIN dw.DimDate AS dm ON dm.DateKey = c.MonthKey * 100 + 1
INNER JOIN dw.DimPlan AS cp ON cp.PlanID  = c.PlanID AND cp.IsCurrent = 1;
GO

/* =============================================================================
   dw.vw_ChurnByCohort
   Question   : how long do subscriptions survive, by the month they started?
   Grain      : signup cohort month x activity (snapshot) month
   CohortSize : subscriptions that started in the cohort month.
   Retention  : subscriptions still alive at the activity month-end, as a % of
                the cohort size - the classic cohort triangle.
   CONSUMED BY: Page 4 - cohort-triangle matrix and the churn line chart.
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_ChurnByCohort
AS
WITH Cohort AS
(
    SELECT s.SignupCohortMonthKey AS CohortMonthKey,
           COUNT(DISTINCT s.SubscriptionID) AS CohortSize
    FROM dw.FactSubscriptionMonthlySnapshot AS s
    WHERE s.SignupCohortMonthKey <> -1
    GROUP BY s.SignupCohortMonthKey
),
Activity AS
(
    SELECT
        s.SignupCohortMonthKey                       AS CohortMonthKey,
        s.SnapshotMonthKey                           AS ActivityMonthKey,
        COUNT(*)                                     AS SubscriptionsObserved,
        SUM(CAST(s.ActiveSubscriptionCount AS INT))  AS SubscriptionsActive,
        SUM(CAST(s.IsChurnedThisMonth AS INT))       AS SubscribersChurned,
        SUM(CAST(s.IsTrialing AS INT))               AS SubscriptionsTrialing
    FROM dw.FactSubscriptionMonthlySnapshot AS s
    WHERE s.SignupCohortMonthKey <> -1
    GROUP BY s.SignupCohortMonthKey, s.SnapshotMonthKey
)
SELECT
    a.CohortMonthKey,
    dc.MonthYearLabel                                                         AS CohortLabel,
    a.ActivityMonthKey,
    da.MonthYearLabel                                                         AS ActivityMonthLabel,
    DATEDIFF(MONTH, dc.FullDate, da.FullDate)                                 AS MonthsSinceSignup,
    c.CohortSize,
    a.SubscriptionsObserved,
    a.SubscriptionsActive,
    a.SubscriptionsTrialing,
    a.SubscribersChurned,
    CAST(100.0 * a.SubscribersChurned  / NULLIF(a.SubscriptionsObserved, 0) AS DECIMAL(5,2)) AS ChurnRatePct,
    CAST(100.0 * a.SubscriptionsActive / NULLIF(c.CohortSize, 0)            AS DECIMAL(5,2)) AS RetentionVsCohortStartPct
FROM Activity AS a
INNER JOIN Cohort     AS c  ON c.CohortMonthKey = a.CohortMonthKey
INNER JOIN dw.DimDate AS dc ON dc.DateKey = a.CohortMonthKey   * 100 + 1
INNER JOIN dw.DimDate AS da ON da.DateKey = a.ActivityMonthKey * 100 + 1;
GO

/* =============================================================================
   dw.vw_GenreEngagementByDayPart
   Question   : which genres are watched at which time of day?
   Grain      : genre x day part
   CONSUMED BY: Page 1 - "Genre x day part" heat-map matrix.
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_GenreEngagementByDayPart
AS
SELECT
    g.GenreName,
    t.DayPart,
    t.DayPartSortOrder,
    CAST(SUM(f.HoursWatched) AS DECIMAL(14,2))                                    AS HoursWatched,
    SUM(CAST(f.SessionCount AS INT))                                              AS SessionCount,
    CAST(AVG(f.PercentComplete) AS DECIMAL(5,2))                                  AS AvgCompletionPct,
    CAST(100.0 * SUM(f.HoursWatched)
         / NULLIF(SUM(SUM(f.HoursWatched)) OVER (PARTITION BY g.GenreName), 0) AS DECIMAL(5,2)) AS ShareOfGenreHoursPct
FROM dw.FactViewingSession AS f
INNER JOIN dw.DimGenre     AS g ON g.GenreKey = f.GenreKey
INNER JOIN dw.DimTimeOfDay AS t ON t.TimeKey  = f.TimeKey
WHERE f.GenreKey <> -1
  AND f.TimeKey  <> -1
GROUP BY g.GenreName, t.DayPart, t.DayPartSortOrder;
GO

/* =============================================================================
   dw.vw_DeviceMixByRegion
   Question   : on which kinds of device is each region watching, and how good
                is the streaming experience there?
   Grain      : region x form factor
   CONSUMED BY: Page 5 - "Device mix by region" 100% stacked bar and the
                "Buffering events per hour" column chart.
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_DeviceMixByRegion
AS
SELECT
    g.RegionName,
    dv.FormFactor,
    CAST(SUM(f.HoursWatched) AS DECIMAL(14,2))                                     AS HoursWatched,
    SUM(CAST(f.SessionCount AS INT))                                               AS SessionCount,
    COUNT(DISTINCT dv.DeviceID)                                                    AS DeviceCount,
    SUM(CAST(f.BufferingEvents AS INT))                                            AS BufferingEvents,
    CAST(SUM(CAST(f.BufferingEvents AS INT)) / NULLIF(SUM(f.HoursWatched), 0) AS DECIMAL(8,2)) AS BufferingEventsPerHour,
    CAST(100.0 * SUM(f.HoursWatched)
         / NULLIF(SUM(SUM(f.HoursWatched)) OVER (PARTITION BY g.RegionName), 0) AS DECIMAL(5,2)) AS ShareOfRegionHoursPct
FROM dw.FactViewingSession AS f
INNER JOIN dw.DimDevice    AS dv ON dv.DeviceKey    = f.DeviceKey
INNER JOIN dw.DimGeography AS g  ON g.GeographyKey  = f.GeographyKey
WHERE f.DeviceKey <> -1
  AND f.GeographyKey <> -1
GROUP BY g.RegionName, dv.FormFactor;
GO

/* =============================================================================
   dw.vw_OriginalsVsLicensedPerformance
   Question   : do HBO Originals earn their share of viewing compared with
                their share of the catalogue?
   Grain      : content source ('HBO Original' / 'Licensed')
   CONSUMED BY: Page 2 - "Originals vs licensed" clustered column chart
                (ShareOfHoursPct vs CatalogueSharePct).
   ============================================================================= */
CREATE OR ALTER VIEW dw.vw_OriginalsVsLicensedPerformance
AS
WITH Catalogue AS
(
    SELECT t.ContentSource, COUNT(*) AS CatalogueTitles
    FROM dw.DimTitle AS t
    WHERE t.TitleKey <> -1
      AND t.IsInCatalog = 1
    GROUP BY t.ContentSource
),
Viewing AS
(
    SELECT
        t.ContentSource,
        COUNT(DISTINCT f.TitleKey)            AS TitlesWatched,
        SUM(f.HoursWatched)                   AS HoursWatched,
        SUM(CAST(f.SessionCount AS INT))      AS SessionCount,
        SUM(CAST(f.IsCompletedFlag AS INT))   AS CompletedSessions
    FROM dw.FactViewingSession AS f
    INNER JOIN dw.DimTitle AS t ON t.TitleKey = f.TitleKey
    WHERE f.TitleKey <> -1
    GROUP BY t.ContentSource
),
Ratings AS
(
    SELECT t.ContentSource, AVG(CAST(r.RatingValue AS DECIMAL(6,2))) AS AvgRating
    FROM dw.FactTitleRating AS r
    INNER JOIN dw.DimTitle AS t ON t.TitleKey = r.TitleKey
    WHERE r.TitleKey <> -1
    GROUP BY t.ContentSource
)
SELECT
    c.ContentSource,
    c.CatalogueTitles,
    ISNULL(v.TitlesWatched, 0)                                                   AS TitlesWatched,
    CAST(ISNULL(v.HoursWatched, 0) AS DECIMAL(14,2))                             AS HoursWatched,
    ISNULL(v.SessionCount, 0)                                                    AS SessionCount,
    CAST(ISNULL(v.HoursWatched, 0) / NULLIF(c.CatalogueTitles, 0) AS DECIMAL(12,2)) AS HoursPerCatalogueTitle,
    CAST(100.0 * v.CompletedSessions / NULLIF(v.SessionCount, 0) AS DECIMAL(5,2)) AS CompletionRatePct,
    CAST(r.AvgRating AS DECIMAL(4,2))                                            AS AvgRating,
    CAST(100.0 * ISNULL(v.HoursWatched, 0)
         / NULLIF(SUM(ISNULL(v.HoursWatched, 0)) OVER (), 0) AS DECIMAL(5,2))     AS ShareOfHoursPct,
    CAST(100.0 * c.CatalogueTitles
         / NULLIF(SUM(c.CatalogueTitles) OVER (), 0) AS DECIMAL(5,2))             AS CatalogueSharePct
FROM Catalogue AS c
LEFT JOIN Viewing AS v ON v.ContentSource = c.ContentSource
LEFT JOIN Ratings AS r ON r.ContentSource = c.ContentSource;
GO

PRINT 'HBOMaxDW: 7 analytic views created.';
GO
