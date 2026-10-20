/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    14_etl_procedures.sql
   Purpose: One load procedure per warehouse table, plus the orchestrator
            etl.usp_RunFullLoad.
   Target:  Microsoft SQL Server 2019+
   Source:  HBOMaxOLTP on the same instance (three-part names throughout).
   Depends: 10, 11, 12 and 13 must have run first.

   Framework contract honoured by EVERY procedure in this file
     1. SET NOCOUNT ON; SET XACT_ABORT ON - so any error aborts the batch and
        the explicit transaction cannot be left half-applied.
     2. The etl.LoadAudit row is INSERTed with status 'Running' BEFORE the
        transaction is opened. A rollback therefore cannot erase the evidence
        that the run happened, and the CATCH block can stamp the failure onto a
        row that definitely exists.
     3. BEGIN TRY / BEGIN TRANSACTION / COMMIT / BEGIN CATCH
        -> IF XACT_STATE() <> 0 ROLLBACK -> update the audit row with
        ERROR_NUMBER / ERROR_LINE / ERROR_MESSAGE -> THROW. The error is both
        recorded and re-raised, so a scheduler still sees the failure.
     4. IDEMPOTENT. Dimensions use MERGE (no WHEN NOT MATCHED BY SOURCE, so the
        -1 Unknown members are never touched). Incremental facts are
        delete-then-insert on their natural key over the reload window. Snapshot
        facts are rebuilt in full. Running any procedure twice leaves the
        warehouse in exactly the same state.
     5. SET-BASED ONLY. There is not a single cursor or WHILE loop in this file.
        Where "pick one row per group" logic is needed it is expressed with
        OUTER APPLY ... TOP (1), which the optimiser resolves as a join.
     6. Unresolved dimension lookups fall back to -1 via ISNULL. A fact row is
        NEVER dropped because a lookup failed.
   ============================================================================= */

USE HBOMaxDW;
GO

/* =============================================================================
   etl.usp_LoadDimDate
   -----------------------------------------------------------------------------
   Target     : dw.DimDate                              Load type: Full (MERGE)
   Source     : none - the calendar is GENERATED, not extracted.
   Range      : 2019-01-01 to 2027-12-31 (the OLTP data window plus headroom so
                that forward-looking rows such as NextBillingDate and
                AvailableUntil always find a date row).
   Technique  : a tally derived from sys.all_objects CROSS JOIN sys.all_objects
                gives more than enough rows; TOP (DATEDIFF(DAY,...)+1) trims it
                to the exact day count. Fully set-based, no loop.
   Weekday    : computed as DATEDIFF(DAY, '1900-01-01', FullDate) % 7 + 1.
                1900-01-01 was a Monday, so this yields the ISO numbering
                1 = Monday .. 7 = Sunday independently of SET DATEFIRST, and the
                day and month names are produced by CASE rather than DATENAME so
                they are independent of SET LANGUAGE too.
   Holidays   : all FIXED-DATE US holidays (New Year's Day, Juneteenth,
                Independence Day, Veterans Day, Christmas Eve, Christmas Day,
                New Year's Eve) plus the six floating federal holidays, which
                are expressible as "the n-th weekday of a month" using the
                deterministic weekday above.
   Fiscal     : fiscal year starts 1 October, so FY2025 runs 2024-10-01 to
                2025-09-30.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimDate;
GO

CREATE PROCEDURE etl.usp_LoadDimDate
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad',
    @StartDate   DATE             = '2019-01-01',
    @EndDate     DATE             = '2027-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT,
            @RowsRead INT = 0,
            @RowsIns  INT = 0,
            @RowsUpd  INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimDate', N'dw.DimDate', 'Full');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SET @RowsRead = DATEDIFF(DAY, @StartDate, @EndDate) + 1;

        BEGIN TRANSACTION;

        WITH Tally AS
        (
            SELECT TOP (DATEDIFF(DAY, @StartDate, @EndDate) + 1)
                   ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS DayOffset
            FROM sys.all_objects a CROSS JOIN sys.all_objects b
        ),
        Base AS
        (
            SELECT CAST(DATEADD(DAY, t.DayOffset, @StartDate) AS DATE) AS FullDate
            FROM Tally t
        ),
        Parts AS
        (
            SELECT
                b.FullDate,
                CONVERT(INT, CONVERT(CHAR(8), b.FullDate, 112))                      AS DateKey,
                CAST(DATEDIFF(DAY, CAST('1900-01-01' AS DATE), b.FullDate) % 7 + 1
                     AS TINYINT)                                                     AS IsoDow,
                CAST(DAY(b.FullDate)              AS TINYINT)                        AS DayNumberOfMonth,
                CAST(DATEPART(DAYOFYEAR, b.FullDate) AS SMALLINT)                    AS DayNumberOfYear,
                CAST(DATEPART(ISO_WEEK, b.FullDate)  AS TINYINT)                     AS IsoWeekOfYear,
                CAST(MONTH(b.FullDate)            AS TINYINT)                        AS MonthNumber,
                CAST(YEAR(b.FullDate)             AS SMALLINT)                       AS YearNumber,
                CAST(DATEPART(QUARTER, b.FullDate) AS TINYINT)                       AS QuarterNumber,
                YEAR(b.FullDate) * 100 + MONTH(b.FullDate)                           AS MonthKey,
                DATEFROMPARTS(YEAR(b.FullDate), MONTH(b.FullDate), 1)                AS MonthStartDate,
                EOMONTH(b.FullDate)                                                  AS MonthEndDate
            FROM Base b
        ),
        Named AS
        (
            SELECT
                p.*,
                CAST(YEAR(DATEADD(DAY, 4 - p.IsoDow, p.FullDate)) AS SMALLINT)       AS IsoYear,
                CAST(CASE p.IsoDow WHEN 1 THEN 'Monday'   WHEN 2 THEN 'Tuesday'
                                   WHEN 3 THEN 'Wednesday' WHEN 4 THEN 'Thursday'
                                   WHEN 5 THEN 'Friday'   WHEN 6 THEN 'Saturday'
                                   ELSE 'Sunday' END AS VARCHAR(9))                  AS DayName,
                CAST(CASE p.IsoDow WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue' WHEN 3 THEN 'Wed'
                                   WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri' WHEN 6 THEN 'Sat'
                                   ELSE 'Sun' END AS VARCHAR(3))                     AS DayNameShort,
                CAST(CASE p.MonthNumber WHEN 1 THEN 'January'  WHEN 2 THEN 'February'
                                        WHEN 3 THEN 'March'    WHEN 4 THEN 'April'
                                        WHEN 5 THEN 'May'      WHEN 6 THEN 'June'
                                        WHEN 7 THEN 'July'     WHEN 8 THEN 'August'
                                        WHEN 9 THEN 'September' WHEN 10 THEN 'October'
                                        WHEN 11 THEN 'November' ELSE 'December'
                     END AS VARCHAR(9))                                              AS MonthName,
                CAST(CASE p.MonthNumber WHEN 1 THEN 'Jan' WHEN 2 THEN 'Feb' WHEN 3 THEN 'Mar'
                                        WHEN 4 THEN 'Apr' WHEN 5 THEN 'May' WHEN 6 THEN 'Jun'
                                        WHEN 7 THEN 'Jul' WHEN 8 THEN 'Aug' WHEN 9 THEN 'Sep'
                                        WHEN 10 THEN 'Oct' WHEN 11 THEN 'Nov' ELSE 'Dec'
                     END AS VARCHAR(3))                                              AS MonthNameShort,
                CAST(CASE WHEN p.IsoDow IN (6, 7) THEN 1 ELSE 0 END AS BIT)          AS IsWeekend,
                CAST(CASE WHEN p.FullDate = p.MonthEndDate THEN 1 ELSE 0 END AS BIT) AS IsLastDayOfMonth,
                CAST(DAY(p.MonthEndDate) AS TINYINT)                                 AS DaysInMonth,
                CAST(p.YearNumber + CASE WHEN p.MonthNumber >= 10 THEN 1 ELSE 0 END
                     AS SMALLINT)                                                    AS FiscalYear,
                CAST(((p.MonthNumber + 2) % 12) + 1 AS TINYINT)                      AS FiscalMonthNumber,
                CAST(CASE
                        WHEN p.MonthNumber = 1  AND p.DayNumberOfMonth = 1  THEN 'New Year''s Day'
                        WHEN p.MonthNumber = 6  AND p.DayNumberOfMonth = 19 THEN 'Juneteenth'
                        WHEN p.MonthNumber = 7  AND p.DayNumberOfMonth = 4  THEN 'Independence Day'
                        WHEN p.MonthNumber = 11 AND p.DayNumberOfMonth = 11 THEN 'Veterans Day'
                        WHEN p.MonthNumber = 12 AND p.DayNumberOfMonth = 24 THEN 'Christmas Eve'
                        WHEN p.MonthNumber = 12 AND p.DayNumberOfMonth = 25 THEN 'Christmas Day'
                        WHEN p.MonthNumber = 12 AND p.DayNumberOfMonth = 31 THEN 'New Year''s Eve'
                        WHEN p.MonthNumber = 1  AND p.IsoDow = 1 AND p.DayNumberOfMonth BETWEEN 15 AND 21
                             THEN 'Martin Luther King Jr. Day'
                        WHEN p.MonthNumber = 2  AND p.IsoDow = 1 AND p.DayNumberOfMonth BETWEEN 15 AND 21
                             THEN 'Presidents Day'
                        WHEN p.MonthNumber = 5  AND p.IsoDow = 1 AND p.DayNumberOfMonth BETWEEN 25 AND 31
                             THEN 'Memorial Day'
                        WHEN p.MonthNumber = 9  AND p.IsoDow = 1 AND p.DayNumberOfMonth BETWEEN 1 AND 7
                             THEN 'Labor Day'
                        WHEN p.MonthNumber = 10 AND p.IsoDow = 1 AND p.DayNumberOfMonth BETWEEN 8 AND 14
                             THEN 'Columbus Day'
                        WHEN p.MonthNumber = 11 AND p.IsoDow = 4 AND p.DayNumberOfMonth BETWEEN 22 AND 28
                             THEN 'Thanksgiving Day'
                        ELSE NULL
                     END AS VARCHAR(40))                                             AS HolidayName
            FROM Parts p
        ),
        Src AS
        (
            SELECT
                n.DateKey, n.FullDate, n.DayNumberOfMonth, n.DayNumberOfYear,
                n.IsoDow AS DayNumberOfWeek, n.DayName, n.DayNameShort,
                n.IsWeekend,
                CAST(CASE WHEN n.HolidayName IS NULL THEN 0 ELSE 1 END AS BIT) AS IsHoliday,
                n.HolidayName, n.IsoWeekOfYear, n.IsoYear,
                n.MonthNumber, n.MonthName, n.MonthNameShort, n.MonthKey,
                CAST(n.MonthNameShort + ' ' + CAST(n.YearNumber AS CHAR(4)) AS VARCHAR(8)) AS MonthYearLabel,
                n.MonthStartDate, n.MonthEndDate, n.IsLastDayOfMonth, n.DaysInMonth,
                n.QuarterNumber,
                CAST('Q' + CAST(n.QuarterNumber AS CHAR(1)) AS VARCHAR(2))             AS QuarterName,
                CAST('Q' + CAST(n.QuarterNumber AS CHAR(1)) + ' '
                         + CAST(n.YearNumber AS CHAR(4)) AS VARCHAR(8))                AS QuarterYearLabel,
                n.YearNumber, n.FiscalYear,
                CAST((n.FiscalMonthNumber + 2) / 3 AS TINYINT)                         AS FiscalQuarter,
                n.FiscalMonthNumber,
                CAST('FY' + CAST(n.FiscalYear AS CHAR(4)) AS VARCHAR(8))               AS FiscalYearLabel
            FROM Named n
        )
        MERGE dw.DimDate AS tgt
        USING Src AS src
            ON tgt.DateKey = src.DateKey
        WHEN MATCHED AND
        (
               tgt.IsHoliday                   <> src.IsHoliday
            OR ISNULL(tgt.HolidayName, '')     <> ISNULL(src.HolidayName, '')
            OR tgt.IsWeekend                   <> src.IsWeekend
            OR tgt.IsLastDayOfMonth            <> src.IsLastDayOfMonth
            OR ISNULL(tgt.FiscalYear, -1)      <> src.FiscalYear
            OR ISNULL(tgt.FiscalQuarter, 0)    <> src.FiscalQuarter
            OR tgt.MonthYearLabel              <> src.MonthYearLabel
        )
        THEN UPDATE SET
                tgt.FullDate          = src.FullDate,
                tgt.DayNumberOfMonth  = src.DayNumberOfMonth,
                tgt.DayNumberOfYear   = src.DayNumberOfYear,
                tgt.DayNumberOfWeek   = src.DayNumberOfWeek,
                tgt.DayName           = src.DayName,
                tgt.DayNameShort      = src.DayNameShort,
                tgt.IsWeekend         = src.IsWeekend,
                tgt.IsHoliday         = src.IsHoliday,
                tgt.HolidayName       = src.HolidayName,
                tgt.IsoWeekOfYear     = src.IsoWeekOfYear,
                tgt.IsoYear           = src.IsoYear,
                tgt.MonthNumber       = src.MonthNumber,
                tgt.MonthName         = src.MonthName,
                tgt.MonthNameShort    = src.MonthNameShort,
                tgt.MonthKey          = src.MonthKey,
                tgt.MonthYearLabel    = src.MonthYearLabel,
                tgt.MonthStartDate    = src.MonthStartDate,
                tgt.MonthEndDate      = src.MonthEndDate,
                tgt.IsLastDayOfMonth  = src.IsLastDayOfMonth,
                tgt.DaysInMonth       = src.DaysInMonth,
                tgt.QuarterNumber     = src.QuarterNumber,
                tgt.QuarterName       = src.QuarterName,
                tgt.QuarterYearLabel  = src.QuarterYearLabel,
                tgt.YearNumber        = src.YearNumber,
                tgt.FiscalYear        = src.FiscalYear,
                tgt.FiscalQuarter     = src.FiscalQuarter,
                tgt.FiscalMonthNumber = src.FiscalMonthNumber,
                tgt.FiscalYearLabel   = src.FiscalYearLabel,
                tgt.RowUpdatedAt      = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (DateKey, FullDate, DayNumberOfMonth, DayNumberOfYear, DayNumberOfWeek,
                    DayName, DayNameShort, IsWeekend, IsHoliday, HolidayName,
                    IsoWeekOfYear, IsoYear, MonthNumber, MonthName, MonthNameShort,
                    MonthKey, MonthYearLabel, MonthStartDate, MonthEndDate,
                    IsLastDayOfMonth, DaysInMonth, QuarterNumber, QuarterName,
                    QuarterYearLabel, YearNumber, FiscalYear, FiscalQuarter,
                    FiscalMonthNumber, FiscalYearLabel)
            VALUES (src.DateKey, src.FullDate, src.DayNumberOfMonth, src.DayNumberOfYear,
                    src.DayNumberOfWeek, src.DayName, src.DayNameShort, src.IsWeekend,
                    src.IsHoliday, src.HolidayName, src.IsoWeekOfYear, src.IsoYear,
                    src.MonthNumber, src.MonthName, src.MonthNameShort, src.MonthKey,
                    src.MonthYearLabel, src.MonthStartDate, src.MonthEndDate,
                    src.IsLastDayOfMonth, src.DaysInMonth, src.QuarterNumber,
                    src.QuarterName, src.QuarterYearLabel, src.YearNumber,
                    src.FiscalYear, src.FiscalQuarter, src.FiscalMonthNumber,
                    src.FiscalYearLabel)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt  = SYSUTCDATETIME(),
               RowsRead     = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0),
               RowsUpdated  = ISNULL(@RowsUpd, 0),
               LoadStatus   = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt  = SYSUTCDATETIME(),
               LoadStatus   = 'Failed',
               ErrorNumber  = ERROR_NUMBER(),
               ErrorLine    = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;

        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimTimeOfDay
   -----------------------------------------------------------------------------
   Target     : dw.DimTimeOfDay                         Load type: Full (MERGE)
   Source     : none - the 24 hour rows are generated.
   DayPart    : 00-01 and 23 Late Night | 02-05 Night | 06-11 Morning |
                12-17 Afternoon | 18-22 Prime Time.
                IsPrimeTime is the 18:00-22:59 window, which is the band the
                prime-time analysis and the genre heat map compare against.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimTimeOfDay;
GO

CREATE PROCEDURE etl.usp_LoadDimTimeOfDay
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimTimeOfDay', N'dw.DimTimeOfDay', 'Full');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        WITH Hours24 AS
        (
            SELECT TOP (24) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS TINYINT) AS Hour24
            FROM sys.all_objects
        ),
        Src AS
        (
            SELECT
                CAST(h.Hour24 AS INT)                                                   AS TimeKey,
                h.Hour24,
                CAST(RIGHT('0' + CAST(h.Hour24 AS VARCHAR(2)), 2) + ':00' AS VARCHAR(5)) AS Hour24Label,
                CAST(CAST(CASE WHEN h.Hour24 % 12 = 0 THEN 12 ELSE h.Hour24 % 12 END AS VARCHAR(2))
                     + ' ' + CASE WHEN h.Hour24 < 12 THEN 'AM' ELSE 'PM' END
                     AS VARCHAR(8))                                                     AS Hour12Label,
                CAST(CASE WHEN h.Hour24 < 12 THEN 'AM' ELSE 'PM' END AS VARCHAR(2))     AS AmPm,
                CAST(CASE WHEN h.Hour24 IN (0, 1, 23)        THEN 'Late Night'
                          WHEN h.Hour24 BETWEEN 2  AND 5     THEN 'Night'
                          WHEN h.Hour24 BETWEEN 6  AND 11    THEN 'Morning'
                          WHEN h.Hour24 BETWEEN 12 AND 17    THEN 'Afternoon'
                          ELSE 'Prime Time' END AS VARCHAR(12))                         AS DayPart,
                CAST(CASE WHEN h.Hour24 BETWEEN 2  AND 5  THEN 1
                          WHEN h.Hour24 BETWEEN 6  AND 11 THEN 2
                          WHEN h.Hour24 BETWEEN 12 AND 17 THEN 3
                          WHEN h.Hour24 BETWEEN 18 AND 22 THEN 4
                          ELSE 5 END AS TINYINT)                                        AS DayPartSortOrder,
                CAST(CASE WHEN h.Hour24 BETWEEN 18 AND 22 THEN 1 ELSE 0 END AS BIT)     AS IsPrimeTime,
                CAST(CASE WHEN h.Hour24 BETWEEN 9  AND 17 THEN 1 ELSE 0 END AS BIT)     AS IsBusinessHour
            FROM Hours24 h
        )
        MERGE dw.DimTimeOfDay AS tgt
        USING Src AS src
            ON tgt.TimeKey = src.TimeKey
        WHEN MATCHED AND (tgt.DayPart <> src.DayPart
                       OR tgt.DayPartSortOrder <> src.DayPartSortOrder
                       OR tgt.IsPrimeTime <> src.IsPrimeTime
                       OR tgt.Hour24Label <> src.Hour24Label)
        THEN UPDATE SET
                tgt.Hour24           = src.Hour24,
                tgt.Hour24Label      = src.Hour24Label,
                tgt.Hour12Label      = src.Hour12Label,
                tgt.AmPm             = src.AmPm,
                tgt.DayPart          = src.DayPart,
                tgt.DayPartSortOrder = src.DayPartSortOrder,
                tgt.IsPrimeTime      = src.IsPrimeTime,
                tgt.IsBusinessHour   = src.IsBusinessHour,
                tgt.RowUpdatedAt     = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (TimeKey, Hour24, Hour24Label, Hour12Label, AmPm, DayPart,
                    DayPartSortOrder, IsPrimeTime, IsBusinessHour)
            VALUES (src.TimeKey, src.Hour24, src.Hour24Label, src.Hour12Label, src.AmPm,
                    src.DayPart, src.DayPartSortOrder, src.IsPrimeTime, src.IsBusinessHour)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = 24,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimGeography
   -----------------------------------------------------------------------------
   Target     : dw.DimGeography                         Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.geo.Country
                (CountryID, IsoAlpha2, IsoAlpha3, CountryName, RegionName,
                 CurrencyCode, LaunchDate, IsLaunched)
   Note       : LaunchDateKey is informational only and is NOT constrained to
                dw.DimDate, because a territory may have launched before the
                calendar window starts. Fact date keys are always resolved by
                joining dw.DimDate so that their foreign keys cannot be violated.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimGeography;
GO

CREATE PROCEDURE etl.usp_LoadDimGeography
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimGeography', N'dw.DimGeography', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.geo.Country;

        BEGIN TRANSACTION;

        MERGE dw.DimGeography AS tgt
        USING
        (
            SELECT c.CountryID, c.IsoAlpha2, c.IsoAlpha3, c.CountryName, c.RegionName,
                   c.CurrencyCode, c.LaunchDate,
                   ISNULL(CONVERT(INT, CONVERT(CHAR(8), c.LaunchDate, 112)), -1) AS LaunchDateKey,
                   c.IsLaunched
            FROM HBOMaxOLTP.geo.Country AS c
        ) AS src
            ON tgt.CountryID = src.CountryID
        WHEN MATCHED AND (tgt.IsoAlpha2 <> src.IsoAlpha2
                       OR tgt.IsoAlpha3 <> src.IsoAlpha3
                       OR tgt.CountryName <> src.CountryName
                       OR tgt.RegionName <> src.RegionName
                       OR tgt.CurrencyCode <> src.CurrencyCode
                       OR ISNULL(tgt.LaunchDate, '1900-01-01') <> ISNULL(src.LaunchDate, '1900-01-01')
                       OR tgt.IsLaunched <> src.IsLaunched)
        THEN UPDATE SET
                tgt.IsoAlpha2     = src.IsoAlpha2,
                tgt.IsoAlpha3     = src.IsoAlpha3,
                tgt.CountryName   = src.CountryName,
                tgt.RegionName    = src.RegionName,
                tgt.CurrencyCode  = src.CurrencyCode,
                tgt.LaunchDate    = src.LaunchDate,
                tgt.LaunchDateKey = src.LaunchDateKey,
                tgt.IsLaunched    = src.IsLaunched,
                tgt.RowUpdatedAt  = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (CountryID, IsoAlpha2, IsoAlpha3, CountryName, RegionName,
                    CurrencyCode, LaunchDate, LaunchDateKey, IsLaunched)
            VALUES (src.CountryID, src.IsoAlpha2, src.IsoAlpha3, src.CountryName,
                    src.RegionName, src.CurrencyCode, src.LaunchDate,
                    src.LaunchDateKey, src.IsLaunched)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimGenre
   -----------------------------------------------------------------------------
   Target     : dw.DimGenre                             Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.cat.Genre (GenreID, GenreName, Description)
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimGenre;
GO

CREATE PROCEDURE etl.usp_LoadDimGenre
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimGenre', N'dw.DimGenre', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.cat.Genre;

        BEGIN TRANSACTION;

        MERGE dw.DimGenre AS tgt
        USING (SELECT g.GenreID, g.GenreName, g.Description
               FROM HBOMaxOLTP.cat.Genre AS g) AS src
            ON tgt.GenreID = src.GenreID
        WHEN MATCHED AND (tgt.GenreName <> src.GenreName
                       OR ISNULL(tgt.GenreDescription, N'') <> ISNULL(src.Description, N''))
        THEN UPDATE SET
                tgt.GenreName        = src.GenreName,
                tgt.GenreDescription = src.Description,
                tgt.RowUpdatedAt     = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (GenreID, GenreName, GenreDescription)
            VALUES (src.GenreID, src.GenreName, src.Description)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimPlan
   -----------------------------------------------------------------------------
   Target     : dw.DimPlan                              Load type: SCD2
   Source     : HBOMaxOLTP.acct.Plan
                (PlanID, PlanCode, PlanName, MonthlyPrice, AnnualPrice,
                 CurrencyCode, MaxConcurrentStreams, MaxVideoQuality,
                 MaxProfiles, AllowsDownloads, HasAdvertising, EffectiveFrom,
                 IsActive)

   SLOWLY CHANGING DIMENSION TYPE 2 - how it is handled here
   ---------------------------------------------------------
   Tracked attributes (a change creates a NEW VERSION of the row):
       MonthlyPrice, AnnualPrice, CurrencyCode, HasAdvertising, MaxVideoQuality.
   Untracked attributes (a change OVERWRITES the current version, Type 1):
       PlanCode, PlanName, MaxConcurrentStreams, MaxProfiles, AllowsDownloads,
       IsActive, SourceEffectiveFrom.

   The load is the classic TWO-STEP pattern, and the two steps are deliberately
   two separate statements rather than one MERGE, because a single MERGE cannot
   both expire a row and insert its replacement in the same pass:

     STEP 1 - EXPIRE. For every plan whose current version has a tracked
              attribute that differs from the source, close the current version:
              RowEffectiveTo = @LoadDate - 1 day, IsCurrent = 0. The OUTPUT
              clause captures the PlanID and the version number of the row that
              was just closed, so step 2 knows exactly which plans changed and
              what the next version number is. Only rows whose RowEffectiveFrom
              is strictly EARLIER than @LoadDate are expired - see step 3.
     STEP 2 - INSERT the new version: RowEffectiveFrom = @LoadDate,
              RowEffectiveTo = 9999-12-31, IsCurrent = 1,
              RowVersion = previous + 1. Fact rows loaded from now on will
              resolve to this version, while the historical fact rows keep
              pointing at the surrogate key of the expired version - which is
              the entire point of Type 2 on price.
     STEP 3 - SAME-DAY CORRECTION plus Type 1 overwrite. Because the effective
              dates are at DAY grain, two versions of the same plan cannot both
              be valid on the same day. If the current version already starts
              today (the ETL has already run today, or the plan is brand new),
              a further change is applied in place instead of creating a second
              same-day version. The same statement also overwrites the untracked
              attributes on every current row, so this single UPDATE covers both
              cases; for a plan that was just versioned in step 2 the values
              already match and nothing is written.
     STEP 4 - INSERT brand-new plans as version 1, effective from the source
              EffectiveFrom date so that history before the first ETL run is
              still attributable.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimPlan;
GO

CREATE PROCEDURE etl.usp_LoadDimPlan
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0, @N INT = 0;
    DECLARE @LoadDate DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @Changed TABLE (PlanID INT PRIMARY KEY, PriorVersion INT NOT NULL);

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimPlan', N'dw.DimPlan', 'SCD2');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---- stage the source with its derived attributes ---- */
        TRUNCATE TABLE etl.StgPlan;

        INSERT INTO etl.StgPlan
        (
            PlanID, PlanCode, PlanName, MonthlyPrice, AnnualPrice, CurrencyCode, PriceBand,
            MaxConcurrentStreams, MaxVideoQuality, MaxProfiles, AllowsDownloads,
            HasAdvertising, AdvertisingLabel, IsActive, SourceEffectiveFrom
        )
        SELECT
            p.PlanID, p.PlanCode, p.PlanName, p.MonthlyPrice, p.AnnualPrice, p.CurrencyCode,
            CAST(CASE WHEN p.MonthlyPrice = 0     THEN 'Free'
                      WHEN p.MonthlyPrice < 10    THEN 'Budget (< 10)'
                      WHEN p.MonthlyPrice < 16    THEN 'Standard (10-15.99)'
                      WHEN p.MonthlyPrice < 20    THEN 'Premium (16-19.99)'
                      ELSE 'Ultra (20+)' END AS VARCHAR(20)),
            p.MaxConcurrentStreams, p.MaxVideoQuality, p.MaxProfiles, p.AllowsDownloads,
            p.HasAdvertising,
            CAST(CASE WHEN p.HasAdvertising = 1 THEN 'With Ads' ELSE 'Ad-Free' END AS VARCHAR(12)),
            p.IsActive, p.EffectiveFrom
        FROM HBOMaxOLTP.acct.Plan AS p;

        SELECT @RowsRead = COUNT(*) FROM etl.StgPlan;

        /* ---- STEP 1: expire the current version of every plan whose tracked
                attributes changed (and whose version did not start today) ---- */
        UPDATE d
           SET RowEffectiveTo = DATEADD(DAY, -1, @LoadDate),
               IsCurrent      = 0,
               RowUpdatedAt   = SYSUTCDATETIME()
        OUTPUT deleted.PlanID, deleted.[RowVersion] INTO @Changed (PlanID, PriorVersion)
          FROM dw.DimPlan AS d
          INNER JOIN etl.StgPlan AS s ON s.PlanID = d.PlanID
         WHERE d.IsCurrent = 1
           AND d.PlanKey <> -1
           AND d.RowEffectiveFrom < @LoadDate
           AND (   d.MonthlyPrice              <> s.MonthlyPrice
                OR ISNULL(d.AnnualPrice, -1)   <> ISNULL(s.AnnualPrice, -1)
                OR d.CurrencyCode              <> s.CurrencyCode
                OR d.HasAdvertising            <> s.HasAdvertising
                OR d.MaxVideoQuality           <> s.MaxVideoQuality);

        SET @N = @@ROWCOUNT;
        SET @RowsUpd = @RowsUpd + @N;

        /* ---- STEP 2: insert the replacement version ---- */
        INSERT INTO dw.DimPlan
        (
            PlanID, PlanCode, PlanName, MonthlyPrice, AnnualPrice, CurrencyCode, PriceBand,
            MaxConcurrentStreams, MaxVideoQuality, MaxProfiles, AllowsDownloads,
            HasAdvertising, AdvertisingLabel, IsActive, SourceEffectiveFrom,
            RowEffectiveFrom, RowEffectiveTo, IsCurrent, [RowVersion]
        )
        SELECT
            s.PlanID, s.PlanCode, s.PlanName, s.MonthlyPrice, s.AnnualPrice, s.CurrencyCode,
            s.PriceBand, s.MaxConcurrentStreams, s.MaxVideoQuality, s.MaxProfiles,
            s.AllowsDownloads, s.HasAdvertising, s.AdvertisingLabel, s.IsActive,
            s.SourceEffectiveFrom,
            @LoadDate, '9999-12-31', 1, c.PriorVersion + 1
        FROM etl.StgPlan AS s
        INNER JOIN @Changed AS c ON c.PlanID = s.PlanID;

        SET @RowsIns = @RowsIns + @@ROWCOUNT;

        /* ---- STEP 3: same-day correction + Type 1 overwrite of untracked
                attributes on whatever row is currently the live version ---- */
        UPDATE d
           SET PlanCode             = s.PlanCode,
               PlanName             = s.PlanName,
               MonthlyPrice         = s.MonthlyPrice,
               AnnualPrice          = s.AnnualPrice,
               CurrencyCode         = s.CurrencyCode,
               PriceBand            = s.PriceBand,
               MaxConcurrentStreams = s.MaxConcurrentStreams,
               MaxVideoQuality      = s.MaxVideoQuality,
               MaxProfiles          = s.MaxProfiles,
               AllowsDownloads      = s.AllowsDownloads,
               HasAdvertising       = s.HasAdvertising,
               AdvertisingLabel     = s.AdvertisingLabel,
               IsActive             = s.IsActive,
               SourceEffectiveFrom  = s.SourceEffectiveFrom,
               RowUpdatedAt         = SYSUTCDATETIME()
          FROM dw.DimPlan AS d
          INNER JOIN etl.StgPlan AS s ON s.PlanID = d.PlanID
         WHERE d.IsCurrent = 1
           AND d.PlanKey <> -1
           AND (   d.PlanCode                  <> s.PlanCode
                OR d.PlanName                  <> s.PlanName
                OR d.MonthlyPrice              <> s.MonthlyPrice
                OR ISNULL(d.AnnualPrice, -1)   <> ISNULL(s.AnnualPrice, -1)
                OR d.CurrencyCode              <> s.CurrencyCode
                OR d.PriceBand                 <> s.PriceBand
                OR d.MaxConcurrentStreams      <> s.MaxConcurrentStreams
                OR d.MaxVideoQuality           <> s.MaxVideoQuality
                OR d.MaxProfiles               <> s.MaxProfiles
                OR d.AllowsDownloads           <> s.AllowsDownloads
                OR d.HasAdvertising            <> s.HasAdvertising
                OR d.IsActive                  <> s.IsActive
                OR ISNULL(d.SourceEffectiveFrom, '1900-01-01') <> s.SourceEffectiveFrom);

        SET @RowsUpd = @RowsUpd + @@ROWCOUNT;

        /* ---- STEP 4: brand-new plans, version 1 ---- */
        INSERT INTO dw.DimPlan
        (
            PlanID, PlanCode, PlanName, MonthlyPrice, AnnualPrice, CurrencyCode, PriceBand,
            MaxConcurrentStreams, MaxVideoQuality, MaxProfiles, AllowsDownloads,
            HasAdvertising, AdvertisingLabel, IsActive, SourceEffectiveFrom,
            RowEffectiveFrom, RowEffectiveTo, IsCurrent, [RowVersion]
        )
        SELECT
            s.PlanID, s.PlanCode, s.PlanName, s.MonthlyPrice, s.AnnualPrice, s.CurrencyCode,
            s.PriceBand, s.MaxConcurrentStreams, s.MaxVideoQuality, s.MaxProfiles,
            s.AllowsDownloads, s.HasAdvertising, s.AdvertisingLabel, s.IsActive,
            s.SourceEffectiveFrom,
            s.SourceEffectiveFrom, '9999-12-31', 1, 1
        FROM etl.StgPlan AS s
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimPlan AS d WHERE d.PlanID = s.PlanID);

        SET @RowsIns = @RowsIns + @@ROWCOUNT;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns, RowsUpdated = @RowsUpd, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimSubscriber
   -----------------------------------------------------------------------------
   Target     : dw.DimSubscriber                        Load type: SCD2
   Source     : HBOMaxOLTP.acct.Subscriber
                (SubscriberID, Email, FirstName, LastName, DateOfBirth, Gender,
                 CountryID, PreferredLanguageID, RegisteredAt, LastLoginAt,
                 MarketingOptIn, AccountStatus)
                joined to geo.Country and cat.Language.

   SLOWLY CHANGING DIMENSION TYPE 2 - how it is handled here
   ---------------------------------------------------------
   Tracked attributes (a change creates a NEW VERSION of the row):
       CountryID - and therefore the denormalised CountryName / IsoAlpha2 /
                   RegionName that travel with it - and AccountStatus.
       Rationale: a subscriber who moves from Germany to Spain, or whose account
       is suspended, must not retroactively move every hour they have ever
       watched and every euro they have ever paid into the new region or the new
       status. Regional viewing trends and churn-by-status would silently
       restate themselves on every load if this were Type 1.
   Untracked attributes (Type 1, overwritten on the current version):
       Email, FirstName, LastName, Gender, MarketingOptIn, LastLoginAt,
       PreferredLanguageName, and the as-of-today derived bands AgeYears /
       AgeBand / TenureMonths / TenureBand. The bands drift every single day, so
       versioning them would create a new row per subscriber per birthday and
       destroy the dimension.

   The pattern is identical to etl.usp_LoadDimPlan: STEP 1 expire, STEP 2 insert
   the replacement version, STEP 3 same-day correction plus Type 1 overwrite,
   STEP 4 insert brand-new subscribers as version 1 effective from their
   registration date so that pre-existing history is attributable.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimSubscriber;
GO

CREATE PROCEDURE etl.usp_LoadDimSubscriber
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @LoadDate DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @Changed TABLE (SubscriberID INT PRIMARY KEY, PriorVersion INT NOT NULL);

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimSubscriber', N'dw.DimSubscriber', 'SCD2');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---- stage the source with its derived attributes ---- */
        TRUNCATE TABLE etl.StgSubscriber;

        INSERT INTO etl.StgSubscriber
        (
            SubscriberID, Email, FirstName, LastName, DateOfBirth, Gender, GenderLabel,
            AgeYears, AgeBand, CountryID, CountryName, IsoAlpha2, RegionName,
            PreferredLanguageName, AccountStatus, MarketingOptIn, RegisteredAt,
            RegistrationDateKey, SignupCohortMonthKey, LastLoginAt, TenureMonths, TenureBand
        )
        SELECT
            s.SubscriberID, s.Email, s.FirstName, s.LastName, s.DateOfBirth, s.Gender,
            CAST(CASE s.Gender WHEN 'M' THEN N'Male' WHEN 'F' THEN N'Female'
                               WHEN 'X' THEN N'Non-binary' ELSE N'Unknown' END AS NVARCHAR(12)),
            a.AgeYears,
            CAST(CASE WHEN a.AgeYears IS NULL    THEN 'Unknown'
                      WHEN a.AgeYears < 18       THEN 'Under 18'
                      WHEN a.AgeYears < 25       THEN '18-24'
                      WHEN a.AgeYears < 35       THEN '25-34'
                      WHEN a.AgeYears < 45       THEN '35-44'
                      WHEN a.AgeYears < 55       THEN '45-54'
                      WHEN a.AgeYears < 65       THEN '55-64'
                      ELSE '65+' END AS VARCHAR(10)),
            s.CountryID, c.CountryName, c.IsoAlpha2, c.RegionName,
            l.LanguageName, s.AccountStatus, s.MarketingOptIn, s.RegisteredAt,
            CONVERT(INT, CONVERT(CHAR(8), CAST(s.RegisteredAt AS DATE), 112)),
            YEAR(s.RegisteredAt) * 100 + MONTH(s.RegisteredAt),
            s.LastLoginAt,
            t.TenureMonths,
            CAST(CASE WHEN t.TenureMonths < 4  THEN '0-3 months'
                      WHEN t.TenureMonths < 7  THEN '4-6 months'
                      WHEN t.TenureMonths < 13 THEN '7-12 months'
                      WHEN t.TenureMonths < 25 THEN '1-2 years'
                      WHEN t.TenureMonths < 61 THEN '2-5 years'
                      ELSE '5+ years' END AS VARCHAR(14))
        FROM HBOMaxOLTP.acct.Subscriber AS s
        INNER JOIN HBOMaxOLTP.geo.Country  AS c ON c.CountryID  = s.CountryID
        INNER JOIN HBOMaxOLTP.cat.Language AS l ON l.LanguageID = s.PreferredLanguageID
        CROSS APPLY
        (
            SELECT CAST(DATEDIFF(YEAR, s.DateOfBirth, @LoadDate)
                        - CASE WHEN MONTH(s.DateOfBirth) > MONTH(@LoadDate)
                                 OR (MONTH(s.DateOfBirth) = MONTH(@LoadDate)
                                     AND DAY(s.DateOfBirth) > DAY(@LoadDate))
                               THEN 1 ELSE 0 END AS SMALLINT) AS AgeYears
        ) AS a
        CROSS APPLY
        (
            SELECT CASE WHEN DATEDIFF(MONTH, CAST(s.RegisteredAt AS DATE), @LoadDate) < 0
                        THEN 0 ELSE DATEDIFF(MONTH, CAST(s.RegisteredAt AS DATE), @LoadDate)
                   END AS TenureMonths
        ) AS t;

        SELECT @RowsRead = COUNT(*) FROM etl.StgSubscriber;

        /* ---- STEP 1: expire the current version where a tracked attribute changed ---- */
        UPDATE d
           SET RowEffectiveTo = DATEADD(DAY, -1, @LoadDate),
               IsCurrent      = 0,
               RowUpdatedAt   = SYSUTCDATETIME()
        OUTPUT deleted.SubscriberID, deleted.[RowVersion] INTO @Changed (SubscriberID, PriorVersion)
          FROM dw.DimSubscriber AS d
          INNER JOIN etl.StgSubscriber AS s ON s.SubscriberID = d.SubscriberID
         WHERE d.IsCurrent = 1
           AND d.SubscriberKey <> -1
           AND d.RowEffectiveFrom < @LoadDate
           AND (   d.CountryID     <> s.CountryID
                OR d.AccountStatus <> s.AccountStatus);

        SET @RowsUpd = @RowsUpd + @@ROWCOUNT;

        /* ---- STEP 2: insert the replacement version ---- */
        INSERT INTO dw.DimSubscriber
        (
            SubscriberID, Email, FirstName, LastName, DateOfBirth, Gender, GenderLabel,
            AgeYears, AgeBand, CountryID, CountryName, IsoAlpha2, RegionName,
            PreferredLanguageName, AccountStatus, MarketingOptIn, RegisteredAt,
            RegistrationDateKey, SignupCohortMonthKey, LastLoginAt, TenureMonths, TenureBand,
            RowEffectiveFrom, RowEffectiveTo, IsCurrent, [RowVersion]
        )
        SELECT
            s.SubscriberID, s.Email, s.FirstName, s.LastName, s.DateOfBirth, s.Gender,
            s.GenderLabel, s.AgeYears, s.AgeBand, s.CountryID, s.CountryName, s.IsoAlpha2,
            s.RegionName, s.PreferredLanguageName, s.AccountStatus, s.MarketingOptIn,
            s.RegisteredAt, s.RegistrationDateKey, s.SignupCohortMonthKey, s.LastLoginAt,
            s.TenureMonths, s.TenureBand,
            @LoadDate, '9999-12-31', 1, c.PriorVersion + 1
        FROM etl.StgSubscriber AS s
        INNER JOIN @Changed AS c ON c.SubscriberID = s.SubscriberID;

        SET @RowsIns = @RowsIns + @@ROWCOUNT;

        /* ---- STEP 3: same-day correction + Type 1 overwrite on the live version ---- */
        UPDATE d
           SET Email                 = s.Email,
               FirstName             = s.FirstName,
               LastName              = s.LastName,
               DateOfBirth           = s.DateOfBirth,
               Gender                = s.Gender,
               GenderLabel           = s.GenderLabel,
               AgeYears              = s.AgeYears,
               AgeBand               = s.AgeBand,
               CountryID             = s.CountryID,
               CountryName           = s.CountryName,
               IsoAlpha2             = s.IsoAlpha2,
               RegionName            = s.RegionName,
               PreferredLanguageName = s.PreferredLanguageName,
               AccountStatus         = s.AccountStatus,
               MarketingOptIn        = s.MarketingOptIn,
               RegisteredAt          = s.RegisteredAt,
               RegistrationDateKey   = s.RegistrationDateKey,
               SignupCohortMonthKey  = s.SignupCohortMonthKey,
               LastLoginAt           = s.LastLoginAt,
               TenureMonths          = s.TenureMonths,
               TenureBand            = s.TenureBand,
               RowUpdatedAt          = SYSUTCDATETIME()
          FROM dw.DimSubscriber AS d
          INNER JOIN etl.StgSubscriber AS s ON s.SubscriberID = d.SubscriberID
         WHERE d.IsCurrent = 1
           AND d.SubscriberKey <> -1
           AND (   d.Email                 <> s.Email
                OR d.FirstName             <> s.FirstName
                OR d.LastName              <> s.LastName
                OR ISNULL(d.DateOfBirth, '1900-01-01') <> s.DateOfBirth
                OR ISNULL(d.Gender, '?')   <> ISNULL(s.Gender, '?')
                OR d.CountryID             <> s.CountryID
                OR d.AccountStatus         <> s.AccountStatus
                OR d.PreferredLanguageName <> s.PreferredLanguageName
                OR d.MarketingOptIn        <> s.MarketingOptIn
                OR ISNULL(d.AgeYears, -1)  <> ISNULL(s.AgeYears, -1)
                OR d.AgeBand               <> s.AgeBand
                OR ISNULL(d.TenureMonths, -1) <> s.TenureMonths
                OR d.TenureBand            <> s.TenureBand
                OR ISNULL(CONVERT(VARCHAR(20), d.LastLoginAt, 120), '')
                   <> ISNULL(CONVERT(VARCHAR(20), s.LastLoginAt, 120), ''));

        SET @RowsUpd = @RowsUpd + @@ROWCOUNT;

        /* ---- STEP 4: brand-new subscribers, version 1 from their registration date ---- */
        INSERT INTO dw.DimSubscriber
        (
            SubscriberID, Email, FirstName, LastName, DateOfBirth, Gender, GenderLabel,
            AgeYears, AgeBand, CountryID, CountryName, IsoAlpha2, RegionName,
            PreferredLanguageName, AccountStatus, MarketingOptIn, RegisteredAt,
            RegistrationDateKey, SignupCohortMonthKey, LastLoginAt, TenureMonths, TenureBand,
            RowEffectiveFrom, RowEffectiveTo, IsCurrent, [RowVersion]
        )
        SELECT
            s.SubscriberID, s.Email, s.FirstName, s.LastName, s.DateOfBirth, s.Gender,
            s.GenderLabel, s.AgeYears, s.AgeBand, s.CountryID, s.CountryName, s.IsoAlpha2,
            s.RegionName, s.PreferredLanguageName, s.AccountStatus, s.MarketingOptIn,
            s.RegisteredAt, s.RegistrationDateKey, s.SignupCohortMonthKey, s.LastLoginAt,
            s.TenureMonths, s.TenureBand,
            CAST(s.RegisteredAt AS DATE), '9999-12-31', 1, 1
        FROM etl.StgSubscriber AS s
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimSubscriber AS d WHERE d.SubscriberID = s.SubscriberID);

        SET @RowsIns = @RowsIns + @@ROWCOUNT;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns, RowsUpdated = @RowsUpd, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

PRINT '14_etl_procedures.sql - part 2 of 4 loaded (DimPlan, DimSubscriber).';
GO

/* =============================================================================
   etl.usp_LoadDimProfile
   -----------------------------------------------------------------------------
   Target     : dw.DimProfile                           Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.acct.Profile joined to cat.Language.
   Technique  : a single MERGE on the natural key ProfileID. The WHEN MATCHED
                clause carries an explicit, NULL-safe change test so that a run
                over unchanged data writes nothing at all and RowUpdatedAt does
                not drift; $action is captured into @Actions so the audit row can
                report inserts and updates separately.
   Derived    : ProfileAudience     - 'Kids' / 'Adult' from IsKidsProfile.
                MaturityCeilingRank - the ten OLTP rating codes mapped onto an
                                      ordinal 1..10 so a report can sort and
                                      compare ceilings numerically.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimProfile;
GO

CREATE PROCEDURE etl.usp_LoadDimProfile
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimProfile', N'dw.DimProfile', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.acct.Profile;

        BEGIN TRANSACTION;

        MERGE dw.DimProfile AS tgt
        USING
        (
            SELECT
                p.ProfileID, p.SubscriberID, p.ProfileName, p.IsKidsProfile,
                CAST(CASE WHEN p.IsKidsProfile = 1 THEN 'Kids' ELSE 'Adult' END
                     AS VARCHAR(6))                                              AS ProfileAudience,
                p.MaturityCeiling,
                CAST(CASE p.MaturityCeiling WHEN 'TV-Y'  THEN 1  WHEN 'G'     THEN 2
                                            WHEN 'TV-G'  THEN 3  WHEN 'PG'    THEN 4
                                            WHEN 'TV-PG' THEN 5  WHEN 'PG-13' THEN 6
                                            WHEN 'TV-14' THEN 7  WHEN 'R'     THEN 8
                                            WHEN 'TV-MA' THEN 9  WHEN 'NC-17' THEN 10
                                            ELSE 0 END AS TINYINT)               AS MaturityCeilingRank,
                p.PreferredLanguageID,
                l.LanguageName                                                   AS PreferredLanguageName,
                l.IsoCode                                                        AS PreferredLanguageIsoCode,
                p.AutoplayNextEpisode, p.CreatedAt,
                ISNULL(dd.DateKey, -1)                                           AS ProfileCreatedDateKey
            FROM HBOMaxOLTP.acct.Profile AS p
            INNER JOIN HBOMaxOLTP.cat.Language AS l ON l.LanguageID = p.PreferredLanguageID
            LEFT  JOIN dw.DimDate AS dd
                   ON dd.DateKey = CONVERT(INT, CONVERT(CHAR(8), CAST(p.CreatedAt AS DATE), 112))
        ) AS src
            ON tgt.ProfileID = src.ProfileID
        WHEN MATCHED AND
        (
               tgt.SubscriberID          <> src.SubscriberID
            OR tgt.ProfileName           <> src.ProfileName
            OR tgt.IsKidsProfile         <> src.IsKidsProfile
            OR tgt.ProfileAudience       <> src.ProfileAudience
            OR tgt.MaturityCeiling       <> src.MaturityCeiling
            OR tgt.MaturityCeilingRank   <> src.MaturityCeilingRank
            OR tgt.PreferredLanguageID   <> src.PreferredLanguageID
            OR tgt.PreferredLanguageName <> src.PreferredLanguageName
            OR ISNULL(tgt.PreferredLanguageIsoCode, '') <> ISNULL(src.PreferredLanguageIsoCode, '')
            OR tgt.AutoplayNextEpisode   <> src.AutoplayNextEpisode
            OR ISNULL(tgt.CreatedAt, '1900-01-01') <> ISNULL(src.CreatedAt, '1900-01-01')
            OR tgt.ProfileCreatedDateKey <> src.ProfileCreatedDateKey
        )
        THEN UPDATE SET
                tgt.SubscriberID             = src.SubscriberID,
                tgt.ProfileName              = src.ProfileName,
                tgt.IsKidsProfile            = src.IsKidsProfile,
                tgt.ProfileAudience          = src.ProfileAudience,
                tgt.MaturityCeiling          = src.MaturityCeiling,
                tgt.MaturityCeilingRank      = src.MaturityCeilingRank,
                tgt.PreferredLanguageID      = src.PreferredLanguageID,
                tgt.PreferredLanguageName    = src.PreferredLanguageName,
                tgt.PreferredLanguageIsoCode = src.PreferredLanguageIsoCode,
                tgt.AutoplayNextEpisode      = src.AutoplayNextEpisode,
                tgt.CreatedAt                = src.CreatedAt,
                tgt.ProfileCreatedDateKey    = src.ProfileCreatedDateKey,
                tgt.RowUpdatedAt             = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ProfileID, SubscriberID, ProfileName, IsKidsProfile, ProfileAudience,
                    MaturityCeiling, MaturityCeilingRank, PreferredLanguageID,
                    PreferredLanguageName, PreferredLanguageIsoCode, AutoplayNextEpisode,
                    CreatedAt, ProfileCreatedDateKey)
            VALUES (src.ProfileID, src.SubscriberID, src.ProfileName, src.IsKidsProfile,
                    src.ProfileAudience, src.MaturityCeiling, src.MaturityCeilingRank,
                    src.PreferredLanguageID, src.PreferredLanguageName,
                    src.PreferredLanguageIsoCode, src.AutoplayNextEpisode,
                    src.CreatedAt, src.ProfileCreatedDateKey)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimTitle
   -----------------------------------------------------------------------------
   Target     : dw.DimTitle                             Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.cat.Title, denormalised against cat.TitleGenre +
                cat.Genre (primary genre), cat.Studio, cat.Language and
                cat.Season + cat.Episode (season / episode counts and runtimes).
   Technique  : one MERGE on TitleID. Because the dimension carries 27 compared
                attributes, many of them nullable, the change test uses the
                EXCEPT idiom - EXISTS (SELECT src... EXCEPT SELECT tgt...) - which
                compares every column with correct NULL semantics in one
                expression instead of 27 ISNULL pairs. Unchanged rows produce an
                empty EXCEPT result and are therefore not touched.

   DENORMALISED / DERIVED ATTRIBUTES
     PrimaryGenreName     the cat.TitleGenre row flagged IsPrimaryGenre, else any
                          genre of the title (OUTER APPLY TOP (1) ordered by
                          IsPrimaryGenre DESC), else the 'Unknown' member.
     StudioName           cat.Studio, 'Unknown' when the title has no studio.
     OriginalLanguageName cat.Language on cat.Title.OriginalLanguageID.
     ReleaseDecade        ReleaseYear floored to the decade, e.g. '1990s'.
     TotalRuntimeMinutes  the title's own RuntimeMinutes for a single programme,
                          the SUM of all episode runtimes for a series.
     RuntimeBand          banded on the PROGRAMME runtime - the title runtime, or
                          the AVERAGE episode runtime for a series - so that a
                          ten-hour series is not simply classified '120+ min'.
     SeasonCount /        COUNT of cat.Season and of cat.Episode beneath it; both
     EpisodeCount         are 0 for a title that has no seasons.
     ContentSource        'HBO Original' when IsHboOriginal, else 'Licensed'.
     IsInCatalog          0 once RemovedFromCatalogAt is set.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimTitle;
GO

CREATE PROCEDURE etl.usp_LoadDimTitle
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimTitle', N'dw.DimTitle', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.cat.Title;

        BEGIN TRANSACTION;

        WITH SeriesShape AS
        (
            /* one row per series title: season count, episode count, episode runtimes */
            SELECT
                se.TitleID,
                CAST(COUNT(DISTINCT se.SeasonID) AS SMALLINT) AS SeasonCount,
                COUNT(ep.EpisodeID)                           AS EpisodeCount,
                SUM(CAST(ep.RuntimeMinutes AS INT))           AS EpisodeRuntimeSum,
                AVG(CAST(ep.RuntimeMinutes AS INT))           AS EpisodeRuntimeAvg
            FROM HBOMaxOLTP.cat.Season AS se
            LEFT JOIN HBOMaxOLTP.cat.Episode AS ep ON ep.SeasonID = se.SeasonID
            GROUP BY se.TitleID
        ),
        Src AS
        (
            SELECT
                t.TitleID,
                t.PrimaryTitle,
                t.OriginalTitle,
                t.TitleType,
                ISNULL(pg.GenreID, -1)                                   AS PrimaryGenreID,
                ISNULL(pg.GenreName, N'Unknown')                         AS PrimaryGenreName,
                t.StudioID,
                ISNULL(st.StudioName, N'Unknown')                        AS StudioName,
                t.OriginalLanguageID,
                l.LanguageName                                           AS OriginalLanguageName,
                t.MaturityRating,
                t.IsHboOriginal,
                CAST(CASE WHEN t.IsHboOriginal = 1 THEN 'HBO Original'
                          ELSE 'Licensed' END AS VARCHAR(12))            AS ContentSource,
                t.ReleaseYear,
                CAST(CAST((t.ReleaseYear / 10) * 10 AS VARCHAR(4)) + 's'
                     AS VARCHAR(10))                                     AS ReleaseDecade,
                t.RuntimeMinutes,
                CAST(CASE WHEN t.TitleType = 'Series' THEN r.EpisodeRuntimeSum
                          ELSE t.RuntimeMinutes END AS INT)              AS TotalRuntimeMinutes,
                CAST(CASE WHEN pr.ProgrammeRuntime IS NULL  THEN 'Unknown'
                          WHEN pr.ProgrammeRuntime < 30     THEN '< 30 min'
                          WHEN pr.ProgrammeRuntime < 60     THEN '30-59 min'
                          WHEN pr.ProgrammeRuntime < 90     THEN '60-89 min'
                          WHEN pr.ProgrammeRuntime < 120    THEN '90-119 min'
                          ELSE '120+ min' END AS VARCHAR(14))            AS RuntimeBand,
                CAST(ISNULL(r.SeasonCount, 0) AS SMALLINT)               AS SeasonCount,
                CAST(ISNULL(r.EpisodeCount, 0) AS INT)                   AS EpisodeCount,
                t.ImdbRating,
                t.AverageUserRating,
                t.UserRatingCount,
                t.ProductionBudgetUsd,
                t.AddedToCatalogAt,
                ISNULL(dd.DateKey, -1)                                   AS AddedToCatalogDateKey,
                t.RemovedFromCatalogAt,
                CAST(CASE WHEN t.RemovedFromCatalogAt IS NULL THEN 1 ELSE 0 END AS BIT) AS IsInCatalog
            FROM HBOMaxOLTP.cat.Title AS t
            INNER JOIN HBOMaxOLTP.cat.Language AS l  ON l.LanguageID = t.OriginalLanguageID
            LEFT  JOIN HBOMaxOLTP.cat.Studio   AS st ON st.StudioID  = t.StudioID
            LEFT  JOIN SeriesShape             AS r  ON r.TitleID    = t.TitleID
            LEFT  JOIN dw.DimDate              AS dd
                   ON dd.DateKey = CONVERT(INT, CONVERT(CHAR(8), CAST(t.AddedToCatalogAt AS DATE), 112))
            OUTER APPLY
            (
                SELECT TOP (1) g.GenreID, g.GenreName
                FROM HBOMaxOLTP.cat.TitleGenre AS tg
                INNER JOIN HBOMaxOLTP.cat.Genre AS g ON g.GenreID = tg.GenreID
                WHERE tg.TitleID = t.TitleID
                ORDER BY tg.IsPrimaryGenre DESC, g.GenreName
            ) AS pg
            CROSS APPLY
            (
                SELECT CASE WHEN t.TitleType = 'Series' THEN r.EpisodeRuntimeAvg
                            ELSE CAST(t.RuntimeMinutes AS INT) END AS ProgrammeRuntime
            ) AS pr
        )
        MERGE dw.DimTitle AS tgt
        USING Src AS src
            ON tgt.TitleID = src.TitleID
        WHEN MATCHED AND EXISTS
        (
            SELECT src.PrimaryTitle, src.OriginalTitle, src.TitleType, src.PrimaryGenreID,
                   src.PrimaryGenreName, src.StudioID, src.StudioName, src.OriginalLanguageID,
                   src.OriginalLanguageName, src.MaturityRating, src.IsHboOriginal,
                   src.ContentSource, src.ReleaseYear, src.ReleaseDecade, src.RuntimeMinutes,
                   src.TotalRuntimeMinutes, src.RuntimeBand, src.SeasonCount, src.EpisodeCount,
                   src.ImdbRating, src.AverageUserRating, src.UserRatingCount,
                   src.ProductionBudgetUsd, src.AddedToCatalogAt, src.AddedToCatalogDateKey,
                   src.RemovedFromCatalogAt, src.IsInCatalog
            EXCEPT
            SELECT tgt.PrimaryTitle, tgt.OriginalTitle, tgt.TitleType, tgt.PrimaryGenreID,
                   tgt.PrimaryGenreName, tgt.StudioID, tgt.StudioName, tgt.OriginalLanguageID,
                   tgt.OriginalLanguageName, tgt.MaturityRating, tgt.IsHboOriginal,
                   tgt.ContentSource, tgt.ReleaseYear, tgt.ReleaseDecade, tgt.RuntimeMinutes,
                   tgt.TotalRuntimeMinutes, tgt.RuntimeBand, tgt.SeasonCount, tgt.EpisodeCount,
                   tgt.ImdbRating, tgt.AverageUserRating, tgt.UserRatingCount,
                   tgt.ProductionBudgetUsd, tgt.AddedToCatalogAt, tgt.AddedToCatalogDateKey,
                   tgt.RemovedFromCatalogAt, tgt.IsInCatalog
        )
        THEN UPDATE SET
                tgt.PrimaryTitle          = src.PrimaryTitle,
                tgt.OriginalTitle         = src.OriginalTitle,
                tgt.TitleType             = src.TitleType,
                tgt.PrimaryGenreID        = src.PrimaryGenreID,
                tgt.PrimaryGenreName      = src.PrimaryGenreName,
                tgt.StudioID              = src.StudioID,
                tgt.StudioName            = src.StudioName,
                tgt.OriginalLanguageID    = src.OriginalLanguageID,
                tgt.OriginalLanguageName  = src.OriginalLanguageName,
                tgt.MaturityRating        = src.MaturityRating,
                tgt.IsHboOriginal         = src.IsHboOriginal,
                tgt.ContentSource         = src.ContentSource,
                tgt.ReleaseYear           = src.ReleaseYear,
                tgt.ReleaseDecade         = src.ReleaseDecade,
                tgt.RuntimeMinutes        = src.RuntimeMinutes,
                tgt.TotalRuntimeMinutes   = src.TotalRuntimeMinutes,
                tgt.RuntimeBand           = src.RuntimeBand,
                tgt.SeasonCount           = src.SeasonCount,
                tgt.EpisodeCount          = src.EpisodeCount,
                tgt.ImdbRating            = src.ImdbRating,
                tgt.AverageUserRating     = src.AverageUserRating,
                tgt.UserRatingCount       = src.UserRatingCount,
                tgt.ProductionBudgetUsd   = src.ProductionBudgetUsd,
                tgt.AddedToCatalogAt      = src.AddedToCatalogAt,
                tgt.AddedToCatalogDateKey = src.AddedToCatalogDateKey,
                tgt.RemovedFromCatalogAt  = src.RemovedFromCatalogAt,
                tgt.IsInCatalog           = src.IsInCatalog,
                tgt.RowUpdatedAt          = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (TitleID, PrimaryTitle, OriginalTitle, TitleType, PrimaryGenreID,
                    PrimaryGenreName, StudioID, StudioName, OriginalLanguageID,
                    OriginalLanguageName, MaturityRating, IsHboOriginal, ContentSource,
                    ReleaseYear, ReleaseDecade, RuntimeMinutes, TotalRuntimeMinutes,
                    RuntimeBand, SeasonCount, EpisodeCount, ImdbRating, AverageUserRating,
                    UserRatingCount, ProductionBudgetUsd, AddedToCatalogAt,
                    AddedToCatalogDateKey, RemovedFromCatalogAt, IsInCatalog)
            VALUES (src.TitleID, src.PrimaryTitle, src.OriginalTitle, src.TitleType,
                    src.PrimaryGenreID, src.PrimaryGenreName, src.StudioID, src.StudioName,
                    src.OriginalLanguageID, src.OriginalLanguageName, src.MaturityRating,
                    src.IsHboOriginal, src.ContentSource, src.ReleaseYear, src.ReleaseDecade,
                    src.RuntimeMinutes, src.TotalRuntimeMinutes, src.RuntimeBand,
                    src.SeasonCount, src.EpisodeCount, src.ImdbRating, src.AverageUserRating,
                    src.UserRatingCount, src.ProductionBudgetUsd, src.AddedToCatalogAt,
                    src.AddedToCatalogDateKey, src.RemovedFromCatalogAt, src.IsInCatalog)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimDevice
   -----------------------------------------------------------------------------
   Target     : dw.DimDevice                            Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.acct.Device
   Derived    : FormFactor collapses the six OLTP DeviceType values into the four
                buckets the device-mix report slices on:
                  'TV / Big Screen' <- SmartTV, Console, StreamStick
                  'Handheld'        <- Mobile
                  'Tablet'          <- Tablet
                  'Computer'        <- Desktop
                Anything else maps to 'Unknown', which is also the only other
                value CK_DimDevice_Form permits.
   Note       : acct.Device.OperatingSystem is nullable but dw.DimDevice declares
                it NOT NULL, so it is coalesced to N'Unknown'.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimDevice;
GO

CREATE PROCEDURE etl.usp_LoadDimDevice
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimDevice', N'dw.DimDevice', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.acct.Device;

        BEGIN TRANSACTION;

        MERGE dw.DimDevice AS tgt
        USING
        (
            SELECT
                d.DeviceID, d.SubscriberID, d.DeviceType,
                CAST(CASE WHEN d.DeviceType IN ('SmartTV', 'Console', 'StreamStick')
                               THEN 'TV / Big Screen'
                          WHEN d.DeviceType = 'Mobile'  THEN 'Handheld'
                          WHEN d.DeviceType = 'Tablet'  THEN 'Tablet'
                          WHEN d.DeviceType = 'Desktop' THEN 'Computer'
                          ELSE 'Unknown' END AS VARCHAR(16))        AS FormFactor,
                d.Manufacturer, d.ModelName,
                CAST(ISNULL(d.OperatingSystem, N'Unknown') AS NVARCHAR(40)) AS OperatingSystem,
                d.AppVersion, d.IsTrusted, d.RegisteredAt, d.LastSeenAt
            FROM HBOMaxOLTP.acct.Device AS d
        ) AS src
            ON tgt.DeviceID = src.DeviceID
        WHEN MATCHED AND
        (
               tgt.SubscriberID    <> src.SubscriberID
            OR tgt.DeviceType      <> src.DeviceType
            OR tgt.FormFactor      <> src.FormFactor
            OR tgt.Manufacturer    <> src.Manufacturer
            OR ISNULL(tgt.ModelName, N'')  <> ISNULL(src.ModelName, N'')
            OR tgt.OperatingSystem <> src.OperatingSystem
            OR ISNULL(tgt.AppVersion, '')  <> ISNULL(src.AppVersion, '')
            OR tgt.IsTrusted       <> src.IsTrusted
            OR ISNULL(tgt.RegisteredAt, '1900-01-01') <> ISNULL(src.RegisteredAt, '1900-01-01')
            OR ISNULL(tgt.LastSeenAt,   '1900-01-01') <> ISNULL(src.LastSeenAt,   '1900-01-01')
        )
        THEN UPDATE SET
                tgt.SubscriberID    = src.SubscriberID,
                tgt.DeviceType      = src.DeviceType,
                tgt.FormFactor      = src.FormFactor,
                tgt.Manufacturer    = src.Manufacturer,
                tgt.ModelName       = src.ModelName,
                tgt.OperatingSystem = src.OperatingSystem,
                tgt.AppVersion      = src.AppVersion,
                tgt.IsTrusted       = src.IsTrusted,
                tgt.RegisteredAt    = src.RegisteredAt,
                tgt.LastSeenAt      = src.LastSeenAt,
                tgt.RowUpdatedAt    = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (DeviceID, SubscriberID, DeviceType, FormFactor, Manufacturer, ModelName,
                    OperatingSystem, AppVersion, IsTrusted, RegisteredAt, LastSeenAt)
            VALUES (src.DeviceID, src.SubscriberID, src.DeviceType, src.FormFactor,
                    src.Manufacturer, src.ModelName, src.OperatingSystem, src.AppVersion,
                    src.IsTrusted, src.RegisteredAt, src.LastSeenAt)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

/* =============================================================================
   etl.usp_LoadDimPaymentMethod
   -----------------------------------------------------------------------------
   Target     : dw.DimPaymentMethod                     Load type: SCD1 (MERGE)
   Source     : HBOMaxOLTP.bill.PaymentMethod joined to geo.Country for the
                billing territory.
   Derived    : MethodCategory - 'Card'    <- CreditCard, DebitCard
                                 'Wallet'  <- PayPal, ApplePay, GooglePay
                                 'Prepaid' <- GiftCard
                                 'Unknown' otherwise.
   Privacy    : only CardBrand and Last4Digits are carried over; no PAN, no
                expiry pairing, no postal code.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadDimPaymentMethod;
GO

CREATE PROCEDURE etl.usp_LoadDimPaymentMethod
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsUpd INT = 0;
    DECLARE @Actions TABLE (MergeAction NVARCHAR(10));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadDimPaymentMethod',
            N'dw.DimPaymentMethod', 'SCD1');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.bill.PaymentMethod;

        BEGIN TRANSACTION;

        MERGE dw.DimPaymentMethod AS tgt
        USING
        (
            SELECT
                pm.PaymentMethodID, pm.SubscriberID, pm.MethodType,
                CAST(CASE WHEN pm.MethodType IN ('CreditCard', 'DebitCard')        THEN 'Card'
                          WHEN pm.MethodType IN ('PayPal', 'ApplePay', 'GooglePay') THEN 'Wallet'
                          WHEN pm.MethodType = 'GiftCard'                           THEN 'Prepaid'
                          ELSE 'Unknown' END AS VARCHAR(8))             AS MethodCategory,
                CAST(ISNULL(pm.CardBrand, 'N/A') AS VARCHAR(20))        AS CardBrand,
                pm.Last4Digits, pm.BillingCountryID,
                c.CountryName                                           AS BillingCountryName,
                c.RegionName                                            AS BillingRegionName,
                pm.IsDefault, pm.IsActive, pm.AddedAt,
                ISNULL(dd.DateKey, -1)                                  AS AddedDateKey
            FROM HBOMaxOLTP.bill.PaymentMethod AS pm
            INNER JOIN HBOMaxOLTP.geo.Country AS c ON c.CountryID = pm.BillingCountryID
            LEFT  JOIN dw.DimDate AS dd
                   ON dd.DateKey = CONVERT(INT, CONVERT(CHAR(8), CAST(pm.AddedAt AS DATE), 112))
        ) AS src
            ON tgt.PaymentMethodID = src.PaymentMethodID
        WHEN MATCHED AND
        (
               tgt.SubscriberID       <> src.SubscriberID
            OR tgt.MethodType         <> src.MethodType
            OR tgt.MethodCategory     <> src.MethodCategory
            OR tgt.CardBrand          <> src.CardBrand
            OR ISNULL(tgt.Last4Digits, '????') <> ISNULL(src.Last4Digits, '????')
            OR tgt.BillingCountryID   <> src.BillingCountryID
            OR tgt.BillingCountryName <> src.BillingCountryName
            OR tgt.BillingRegionName  <> src.BillingRegionName
            OR tgt.IsDefault          <> src.IsDefault
            OR tgt.IsActive           <> src.IsActive
            OR ISNULL(tgt.AddedAt, '1900-01-01') <> ISNULL(src.AddedAt, '1900-01-01')
            OR tgt.AddedDateKey       <> src.AddedDateKey
        )
        THEN UPDATE SET
                tgt.SubscriberID       = src.SubscriberID,
                tgt.MethodType         = src.MethodType,
                tgt.MethodCategory     = src.MethodCategory,
                tgt.CardBrand          = src.CardBrand,
                tgt.Last4Digits        = src.Last4Digits,
                tgt.BillingCountryID   = src.BillingCountryID,
                tgt.BillingCountryName = src.BillingCountryName,
                tgt.BillingRegionName  = src.BillingRegionName,
                tgt.IsDefault          = src.IsDefault,
                tgt.IsActive           = src.IsActive,
                tgt.AddedAt            = src.AddedAt,
                tgt.AddedDateKey       = src.AddedDateKey,
                tgt.RowUpdatedAt       = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (PaymentMethodID, SubscriberID, MethodType, MethodCategory, CardBrand,
                    Last4Digits, BillingCountryID, BillingCountryName, BillingRegionName,
                    IsDefault, IsActive, AddedAt, AddedDateKey)
            VALUES (src.PaymentMethodID, src.SubscriberID, src.MethodType, src.MethodCategory,
                    src.CardBrand, src.Last4Digits, src.BillingCountryID,
                    src.BillingCountryName, src.BillingRegionName, src.IsDefault,
                    src.IsActive, src.AddedAt, src.AddedDateKey)
        OUTPUT $action INTO @Actions (MergeAction);

        SELECT @RowsIns = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
               @RowsUpd = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
        FROM @Actions;

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = ISNULL(@RowsIns, 0), RowsUpdated = ISNULL(@RowsUpd, 0),
               LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

PRINT '14_etl_procedures.sql - part 3 of 4 loaded (DimProfile, DimTitle, DimDevice, DimPaymentMethod).';
GO


/* #############################################################################
   PART 4 OF 4 - FACT LOADS AND THE ORCHESTRATOR
   -----------------------------------------------------------------------------
   Contents
     etl.utvf_PlanInForce                 helper: plan of a subscription at a moment
     etl.usp_LoadFactViewingSession       Incremental (watermark on StartedAt)
     etl.usp_LoadFactRevenue              Incremental (watermark on PaidAt)
     etl.usp_LoadFactTitleRating          Incremental (watermark on CreatedAt/UpdatedAt)
     etl.usp_LoadFactSubscriptionMonthlySnapshot   Snapshot (full rebuild)
     etl.usp_LoadFactCatalogAvailabilitySnapshot   Snapshot (full rebuild)
     etl.usp_RunFullLoad                  orchestrator - dimensions, then facts

   Shared rules for the fact loads (in addition to the framework contract at the
   top of this file)
     * POINT-IN-TIME LOOKUPS on the two SCD Type 2 dimensions. A fact row is
       attached to the DimSubscriber / DimPlan version whose
       [RowEffectiveFrom, RowEffectiveTo] window contains the event date. If the
       event predates the first version (a version 1 row starts on the
       registration / plan EffectiveFrom date, and source data can be
       back-dated), the EARLIEST version is used instead of -1, because the
       business entity is known - only its history is not.
       Pattern: OUTER APPLY (SELECT TOP (1) ... ORDER BY <in window> , RowEffectiveFrom).
     * EVERY DATE KEY IS RESOLVED BY A JOIN TO dw.DimDate, never by arithmetic
       alone, so a date outside the generated calendar lands on -1 instead of
       violating the foreign key.
     * INCREMENTAL WINDOW. @From = LastLoadedDateTime - LookbackMinutes (from
       etl.LoadWatermark). NULL watermark, or @FullReload = 1, means "everything"
       and the fact is emptied first. The watermark is only advanced inside the
       committed transaction, so a failed run re-reads the same window.
   ############################################################################# */


/* =============================================================================
   etl.utvf_PlanInForce
   -----------------------------------------------------------------------------
   Returns the PlanID a subscription was on at @AsOf.
   acct.Subscription only stores the CURRENT plan; history lives in
   audit.SubscriptionChangeLog (written by acct.trg_Subscription_Audit). So:
     1. the NewPlanID of the latest plan change at or before @AsOf, else
     2. the OldPlanID of the earliest plan change after @AsOf (the subscription
        has changed plan since, so before that change it was on the old plan),
        else
     3. the current acct.Subscription.PlanID (it never changed plan).
   Inline table-valued function, so OUTER APPLY of it is expanded into the
   calling query by the optimiser - no row-by-row execution.
   ============================================================================= */
DROP FUNCTION IF EXISTS etl.utvf_PlanInForce;
GO

CREATE FUNCTION etl.utvf_PlanInForce
(
    @SubscriptionID INT,
    @AsOf           DATETIME2(0)
)
RETURNS TABLE
AS
RETURN
(
    SELECT COALESCE(
               (SELECT TOP (1) l.NewPlanID
                  FROM HBOMaxOLTP.[audit].SubscriptionChangeLog AS l
                 WHERE l.SubscriptionID = @SubscriptionID
                   AND l.ChangeType IN ('PlanChange', 'PlanAndStatusChange')
                   AND l.ChangedAt <= @AsOf
                 ORDER BY l.ChangedAt DESC, l.ChangeLogID DESC),
               (SELECT TOP (1) l.OldPlanID
                  FROM HBOMaxOLTP.[audit].SubscriptionChangeLog AS l
                 WHERE l.SubscriptionID = @SubscriptionID
                   AND l.ChangeType IN ('PlanChange', 'PlanAndStatusChange')
                   AND l.ChangedAt > @AsOf
                 ORDER BY l.ChangedAt ASC, l.ChangeLogID ASC),
               (SELECT sub.PlanID
                  FROM HBOMaxOLTP.acct.Subscription AS sub
                 WHERE sub.SubscriptionID = @SubscriptionID)
           ) AS PlanID
);
GO


/* =============================================================================
   etl.usp_LoadFactViewingSession
   -----------------------------------------------------------------------------
   Target     : dw.FactViewingSession                   Load type: Incremental
   Source     : HBOMaxOLTP.play.WatchSession, with acct.Profile (owning
                subscriber), cat.TitleGenre (primary genre) and
                acct.Subscription + etl.utvf_PlanInForce (plan on the day).
   Staging    : etl.StgWatchSession
   Watermark  : StartedAt, 3-day lookback.
   Derivations
     SubscriberID   acct.Profile.SubscriberID.
     PrimaryGenreID cat.TitleGenre flagged IsPrimaryGenre, else the first genre
                    by name - the same rule as etl.usp_LoadDimTitle, so the
                    fact's GenreKey always agrees with DimTitle.PrimaryGenreName.
     PlanID         the subscription of that subscriber that was live on the
                    session date (latest StartDate wins if two overlap), then
                    the plan that subscription was on at StartedAt. NULL when no
                    subscription covered the date -> PlanKey -1.
     IsBingeSession 1 when the same profile had another session on the same
                    title on the same calendar day. Evaluated against the WHOLE
                    source table (not only the load window), as the fact header
                    promises.
     EpisodeID      NULL (films, specials) stored as 0 = not an episode.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadFactViewingSession;
GO

CREATE PROCEDURE etl.usp_LoadFactViewingSession
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad',
    @FullReload  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsDel INT = 0,
            @Unresolved INT = 0;
    DECLARE @From DATETIME2(3), @Lookback INT, @LastMark DATETIME2(3), @NewMark DATETIME2(3);

    SET @BatchID = ISNULL(@BatchID, NEWID());

    SELECT @LastMark = w.LastLoadedDateTime, @Lookback = w.LookbackMinutes
      FROM etl.LoadWatermark AS w
     WHERE w.TargetObject = N'dw.FactViewingSession';

    IF @FullReload = 1 OR @LastMark IS NULL
        SET @From = '1900-01-01';
    ELSE
        SET @From = DATEADD(MINUTE, -ISNULL(@Lookback, 4320), @LastMark);

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadFactViewingSession', N'dw.FactViewingSession',
            CASE WHEN @From = '1900-01-01' THEN 'Full' ELSE 'Incremental' END);
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---- EXTRACT: the load window, with business keys pre-resolved ---- */
        TRUNCATE TABLE etl.StgWatchSession;

        INSERT INTO etl.StgWatchSession
        (
            WatchSessionID, ProfileID, SubscriberID, TitleID, EpisodeID, PrimaryGenreID,
            DeviceID, CountryID, PlanID, StartedAt, EndedAt, SessionDate, SessionDateKey,
            SessionHour, SecondsWatched, PercentComplete, VideoQuality, IsCompleted,
            BufferingEvents, IsBingeSession
        )
        SELECT
            ws.WatchSessionID,
            ws.ProfileID,
            p.SubscriberID,
            ws.TitleID,
            ws.EpisodeID,
            pg.GenreID,
            ws.DeviceID,
            ws.CountryID,
            pif.PlanID,
            ws.StartedAt,
            ws.EndedAt,
            CAST(ws.StartedAt AS DATE),
            CONVERT(INT, CONVERT(CHAR(8), CAST(ws.StartedAt AS DATE), 112)),
            DATEPART(HOUR, ws.StartedAt),
            ws.SecondsWatched,
            ws.PercentComplete,
            ws.VideoQuality,
            ws.IsCompleted,
            ws.BufferingEvents,
            CASE WHEN EXISTS (SELECT 1
                                FROM HBOMaxOLTP.play.WatchSession AS o
                               WHERE o.ProfileID = ws.ProfileID
                                 AND o.TitleID   = ws.TitleID
                                 AND o.WatchSessionID <> ws.WatchSessionID
                                 AND o.StartedAt >= CAST(CAST(ws.StartedAt AS DATE) AS DATETIME2(0))
                                 AND o.StartedAt <  DATEADD(DAY, 1, CAST(CAST(ws.StartedAt AS DATE) AS DATETIME2(0))))
                 THEN 1 ELSE 0 END
        FROM HBOMaxOLTP.play.WatchSession AS ws
        INNER JOIN HBOMaxOLTP.acct.Profile AS p ON p.ProfileID = ws.ProfileID
        OUTER APPLY
        (
            SELECT TOP (1) tg.GenreID
            FROM HBOMaxOLTP.cat.TitleGenre AS tg
            INNER JOIN HBOMaxOLTP.cat.Genre AS g ON g.GenreID = tg.GenreID
            WHERE tg.TitleID = ws.TitleID
            ORDER BY tg.IsPrimaryGenre DESC, g.GenreName
        ) AS pg
        OUTER APPLY
        (
            SELECT TOP (1) sub.SubscriptionID
            FROM HBOMaxOLTP.acct.Subscription AS sub
            WHERE sub.SubscriberID = p.SubscriberID
              AND sub.StartDate <= CAST(ws.StartedAt AS DATE)
              AND (sub.EndDate IS NULL OR sub.EndDate >= CAST(ws.StartedAt AS DATE))
            ORDER BY sub.StartDate DESC, sub.SubscriptionID DESC
        ) AS live
        OUTER APPLY etl.utvf_PlanInForce(live.SubscriptionID, ws.StartedAt) AS pif
        WHERE ws.StartedAt >= @From;

        SELECT @RowsRead = COUNT(*), @NewMark = MAX(StartedAt) FROM etl.StgWatchSession;

        /* ---- DELETE: the whole fact on a full reload, else the re-read rows ---- */
        IF @From = '1900-01-01'
            DELETE FROM dw.FactViewingSession;
        ELSE
            DELETE f
              FROM dw.FactViewingSession AS f
              INNER JOIN etl.StgWatchSession AS s ON s.WatchSessionID = f.WatchSessionID;

        SET @RowsDel = @@ROWCOUNT;

        /* ---- INSERT with surrogate-key lookups, -1 on any miss ---- */
        INSERT INTO dw.FactViewingSession
        (
            DateKey, TimeKey, ProfileKey, SubscriberKey, TitleKey, GenreKey, DeviceKey,
            GeographyKey, PlanKey, WatchSessionID, EpisodeID, VideoQuality, StartedAt,
            EndedAt, SecondsWatched, PercentComplete, IsCompletedFlag, SessionCount,
            BufferingEvents, IsBingeSession, BatchID
        )
        SELECT
            ISNULL(dd.DateKey, -1),
            ISNULL(tod.TimeKey, -1),
            ISNULL(dp.ProfileKey, -1),
            ISNULL(dsv.SubscriberKey, -1),
            ISNULL(dt.TitleKey, -1),
            ISNULL(dg.GenreKey, -1),
            ISNULL(dv.DeviceKey, -1),
            ISNULL(geo.GeographyKey, -1),
            ISNULL(dpl.PlanKey, -1),
            s.WatchSessionID,
            ISNULL(s.EpisodeID, 0),
            s.VideoQuality,
            s.StartedAt,
            s.EndedAt,
            s.SecondsWatched,
            s.PercentComplete,
            CAST(s.IsCompleted AS TINYINT),
            1,
            s.BufferingEvents,
            s.IsBingeSession,
            @BatchID
        FROM etl.StgWatchSession AS s
        LEFT JOIN dw.DimDate       AS dd  ON dd.DateKey      = s.SessionDateKey
        LEFT JOIN dw.DimTimeOfDay  AS tod ON tod.TimeKey     = s.SessionHour
        LEFT JOIN dw.DimProfile    AS dp  ON dp.ProfileID    = s.ProfileID
        LEFT JOIN dw.DimTitle      AS dt  ON dt.TitleID      = s.TitleID
        LEFT JOIN dw.DimGenre      AS dg  ON dg.GenreID      = s.PrimaryGenreID
        LEFT JOIN dw.DimDevice     AS dv  ON dv.DeviceID     = s.DeviceID
        LEFT JOIN dw.DimGeography  AS geo ON geo.CountryID   = s.CountryID
        OUTER APPLY
        (
            SELECT TOP (1) d.SubscriberKey
            FROM dw.DimSubscriber AS d
            WHERE d.SubscriberID = s.SubscriberID
              AND d.SubscriberKey <> -1
            ORDER BY CASE WHEN s.SessionDate BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dsv
        OUTER APPLY
        (
            SELECT TOP (1) d.PlanKey
            FROM dw.DimPlan AS d
            WHERE d.PlanID = s.PlanID
              AND d.PlanKey <> -1
            ORDER BY CASE WHEN s.SessionDate BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dpl;

        SET @RowsIns = @@ROWCOUNT;

        SELECT @Unresolved = COUNT(*)
          FROM dw.FactViewingSession
         WHERE BatchID = @BatchID
           AND -1 IN (DateKey, TimeKey, ProfileKey, SubscriberKey, TitleKey, GenreKey,
                      DeviceKey, GeographyKey, PlanKey);

        /* ---- advance the watermark only when something was read ---- */
        UPDATE etl.LoadWatermark
           SET LastLoadedDateTime = CASE WHEN @NewMark IS NULL THEN LastLoadedDateTime
                                         WHEN LastLoadedDateTime IS NULL OR @NewMark > LastLoadedDateTime
                                              OR @From = '1900-01-01' THEN @NewMark
                                         ELSE LastLoadedDateTime END,
               LastLoadAt         = SYSUTCDATETIME(),
               RowsLastLoad       = @RowsIns,
               RowUpdatedAt       = SYSUTCDATETIME()
         WHERE TargetObject = N'dw.FactViewingSession';

        COMMIT TRANSACTION;

        /* RowsUpdated = rows replaced by the delete-then-insert of the overlap;
           RowsRejected = rows kept but attached to at least one Unknown member. */
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns - CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsUpdated  = CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsRejected = @Unresolved, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO


/* =============================================================================
   etl.usp_LoadFactRevenue
   -----------------------------------------------------------------------------
   Target     : dw.FactRevenue                          Load type: Incremental
   Source     : HBOMaxOLTP.bill.Payment joined to bill.Invoice,
                acct.Subscription and bill.PaymentMethod.
   Staging    : etl.StgPayment
   Watermark  : PaidAt, 3-day lookback. A payment's status can still move
                (Pending -> Succeeded, Succeeded -> Refunded) after PaidAt and
                the source has no UpdatedAt column, so the lookback is what
                picks those changes up. A status change older than the lookback
                needs @FullReload = 1 - see the open items in docs/ARCHITECTURE.md.
   Derivations
     AllocationRatio  Amount / Invoice.TotalAmount for Succeeded and Refunded
                      payments; 0 for Failed and Pending, so attempts that did not
                      settle cannot inflate billed revenue. Capped at 1.
     Subtotal/Discount/Tax  invoice amounts x AllocationRatio.
     PaidAmount       Amount when Succeeded or Refunded, else 0.
     RefundedAmount   Amount when Refunded, else 0. NetRevenueAmount (computed
                      column) = Paid - Refunded, so a refund nets to zero.
     DaysToPay        IssuedDate -> PaidAt for settled payments, NULL otherwise.
     PlanID           the plan the subscription was on when the invoice was
                      ISSUED (etl.utvf_PlanInForce), priced from the DimPlan
                      version in force on that date.
     Geography        the BILLING country of the payment instrument.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadFactRevenue;
GO

CREATE PROCEDURE etl.usp_LoadFactRevenue
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad',
    @FullReload  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsDel INT = 0,
            @Unresolved INT = 0;
    DECLARE @From DATETIME2(3), @Lookback INT, @LastMark DATETIME2(3), @NewMark DATETIME2(3);

    SET @BatchID = ISNULL(@BatchID, NEWID());

    SELECT @LastMark = w.LastLoadedDateTime, @Lookback = w.LookbackMinutes
      FROM etl.LoadWatermark AS w
     WHERE w.TargetObject = N'dw.FactRevenue';

    IF @FullReload = 1 OR @LastMark IS NULL
        SET @From = '1900-01-01';
    ELSE
        SET @From = DATEADD(MINUTE, -ISNULL(@Lookback, 4320), @LastMark);

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadFactRevenue', N'dw.FactRevenue',
            CASE WHEN @From = '1900-01-01' THEN 'Full' ELSE 'Incremental' END);
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        TRUNCATE TABLE etl.StgPayment;

        INSERT INTO etl.StgPayment
        (
            PaymentID, InvoiceID, InvoiceNumber, SubscriptionID, SubscriberID, PlanID,
            PaymentMethodID, BillingCountryID, IssuedDate, PaidAt, PaidDate, PaidHour,
            InvoiceDateKey, PaymentDateKey, PeriodStart, PeriodEnd, InvoiceStatus,
            PaymentStatus, CurrencyCode, InvoiceSubtotal, InvoiceDiscount, InvoiceTax,
            InvoiceTotal, PaymentAmount, AllocationRatio, DaysToPay
        )
        SELECT
            pay.PaymentID,
            inv.InvoiceID,
            inv.InvoiceNumber,
            inv.SubscriptionID,
            sub.SubscriberID,
            ISNULL(pif.PlanID, sub.PlanID),
            pay.PaymentMethodID,
            pm.BillingCountryID,
            inv.IssuedDate,
            pay.PaidAt,
            CAST(pay.PaidAt AS DATE),
            DATEPART(HOUR, pay.PaidAt),
            CONVERT(INT, CONVERT(CHAR(8), inv.IssuedDate, 112)),
            CONVERT(INT, CONVERT(CHAR(8), CAST(pay.PaidAt AS DATE), 112)),
            inv.PeriodStart,
            inv.PeriodEnd,
            inv.InvoiceStatus,
            pay.PaymentStatus,
            pay.CurrencyCode,
            inv.SubtotalAmount,
            inv.DiscountAmount,
            inv.TaxAmount,
            inv.TotalAmount,
            pay.Amount,
            CAST(CASE WHEN pay.PaymentStatus NOT IN ('Succeeded', 'Refunded') THEN 0
                      WHEN inv.TotalAmount = 0                                THEN 0
                      WHEN pay.Amount >= inv.TotalAmount                      THEN 1
                      ELSE pay.Amount / inv.TotalAmount END AS DECIMAL(9,6)),
            CASE WHEN pay.PaymentStatus IN ('Succeeded', 'Refunded')
                 THEN DATEDIFF(DAY, inv.IssuedDate, CAST(pay.PaidAt AS DATE)) END
        FROM HBOMaxOLTP.bill.Payment AS pay
        INNER JOIN HBOMaxOLTP.bill.Invoice       AS inv ON inv.InvoiceID       = pay.InvoiceID
        INNER JOIN HBOMaxOLTP.acct.Subscription  AS sub ON sub.SubscriptionID  = inv.SubscriptionID
        INNER JOIN HBOMaxOLTP.bill.PaymentMethod AS pm  ON pm.PaymentMethodID  = pay.PaymentMethodID
        OUTER APPLY etl.utvf_PlanInForce(inv.SubscriptionID,
                                         CAST(inv.IssuedDate AS DATETIME2(0))) AS pif
        WHERE pay.PaidAt >= @From;

        SELECT @RowsRead = COUNT(*), @NewMark = MAX(PaidAt) FROM etl.StgPayment;

        IF @From = '1900-01-01'
            DELETE FROM dw.FactRevenue;
        ELSE
            DELETE f
              FROM dw.FactRevenue AS f
              INNER JOIN etl.StgPayment AS s ON s.PaymentID = f.PaymentID;

        SET @RowsDel = @@ROWCOUNT;

        INSERT INTO dw.FactRevenue
        (
            InvoiceDateKey, PaymentDateKey, TimeKey, SubscriberKey, PlanKey, GeographyKey,
            PaymentMethodKey, PaymentID, InvoiceID, InvoiceNumber, SubscriptionID,
            PaymentStatus, InvoiceStatus, CurrencyCode, BillingPeriodStart, BillingPeriodEnd,
            SubtotalAmount, DiscountAmount, TaxAmount, PaidAmount, RefundedAmount,
            PaymentCount, FailedPaymentCount, DaysToPay, BatchID
        )
        SELECT
            ISNULL(ddi.DateKey, -1),
            ISNULL(ddp.DateKey, -1),
            ISNULL(tod.TimeKey, -1),
            ISNULL(dsv.SubscriberKey, -1),
            ISNULL(dpl.PlanKey, -1),
            ISNULL(geo.GeographyKey, -1),
            ISNULL(dpm.PaymentMethodKey, -1),
            s.PaymentID,
            s.InvoiceID,
            s.InvoiceNumber,
            s.SubscriptionID,
            s.PaymentStatus,
            s.InvoiceStatus,
            s.CurrencyCode,
            s.PeriodStart,
            s.PeriodEnd,
            CAST(ROUND(s.InvoiceSubtotal * s.AllocationRatio, 2) AS DECIMAL(12,2)),
            CAST(ROUND(s.InvoiceDiscount * s.AllocationRatio, 2) AS DECIMAL(12,2)),
            CAST(ROUND(s.InvoiceTax      * s.AllocationRatio, 2) AS DECIMAL(12,2)),
            CASE WHEN s.PaymentStatus IN ('Succeeded', 'Refunded') THEN s.PaymentAmount ELSE 0 END,
            CASE WHEN s.PaymentStatus = 'Refunded'                 THEN s.PaymentAmount ELSE 0 END,
            1,
            CASE WHEN s.PaymentStatus = 'Failed' THEN 1 ELSE 0 END,
            s.DaysToPay,
            @BatchID
        FROM etl.StgPayment AS s
        LEFT JOIN dw.DimDate          AS ddi ON ddi.DateKey         = s.InvoiceDateKey
        LEFT JOIN dw.DimDate          AS ddp ON ddp.DateKey         = s.PaymentDateKey
        LEFT JOIN dw.DimTimeOfDay     AS tod ON tod.TimeKey         = s.PaidHour
        LEFT JOIN dw.DimGeography     AS geo ON geo.CountryID       = s.BillingCountryID
        LEFT JOIN dw.DimPaymentMethod AS dpm ON dpm.PaymentMethodID = s.PaymentMethodID
        OUTER APPLY
        (
            SELECT TOP (1) d.SubscriberKey
            FROM dw.DimSubscriber AS d
            WHERE d.SubscriberID = s.SubscriberID
              AND d.SubscriberKey <> -1
            ORDER BY CASE WHEN s.PaidDate BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dsv
        OUTER APPLY
        (
            SELECT TOP (1) d.PlanKey
            FROM dw.DimPlan AS d
            WHERE d.PlanID = s.PlanID
              AND d.PlanKey <> -1
            ORDER BY CASE WHEN s.IssuedDate BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dpl;

        SET @RowsIns = @@ROWCOUNT;

        SELECT @Unresolved = COUNT(*)
          FROM dw.FactRevenue
         WHERE BatchID = @BatchID
           AND -1 IN (InvoiceDateKey, PaymentDateKey, TimeKey, SubscriberKey, PlanKey,
                      GeographyKey, PaymentMethodKey);

        UPDATE etl.LoadWatermark
           SET LastLoadedDateTime = CASE WHEN @NewMark IS NULL THEN LastLoadedDateTime
                                         WHEN LastLoadedDateTime IS NULL OR @NewMark > LastLoadedDateTime
                                              OR @From = '1900-01-01' THEN @NewMark
                                         ELSE LastLoadedDateTime END,
               LastLoadAt         = SYSUTCDATETIME(),
               RowsLastLoad       = @RowsIns,
               RowUpdatedAt       = SYSUTCDATETIME()
         WHERE TargetObject = N'dw.FactRevenue';

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns - CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsUpdated  = CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsRejected = @Unresolved, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO


/* =============================================================================
   etl.usp_LoadFactTitleRating
   -----------------------------------------------------------------------------
   Target     : dw.FactTitleRating                      Load type: Incremental
   Source     : HBOMaxOLTP.play.Review joined to acct.Profile and
                acct.Subscriber; primary genre from cat.TitleGenre.
   Staging    : etl.StgReview
   Watermark  : the seeded column is CreatedAt, but a review can be EDITED
                (play.usp_AddOrUpdateReview stamps UpdatedAt), so the window is
                CreatedAt >= @From OR UpdatedAt >= @From, and the mark advances
                to the latest of the two. An edited review is therefore
                re-extracted and replaced on its natural key ReviewID.
   Derivations
     HasTextFlag    1 when ReviewText is not blank.
     ReviewLength   LEN(ReviewText), 0 when there is none.
     Geography      the country of the DimSubscriber VERSION in force on the
                    review date (falls back to the subscriber's current country).
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadFactTitleRating;
GO

CREATE PROCEDURE etl.usp_LoadFactTitleRating
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad',
    @FullReload  BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsDel INT = 0,
            @Unresolved INT = 0;
    DECLARE @From DATETIME2(3), @Lookback INT, @LastMark DATETIME2(3), @NewMark DATETIME2(3);

    SET @BatchID = ISNULL(@BatchID, NEWID());

    SELECT @LastMark = w.LastLoadedDateTime, @Lookback = w.LookbackMinutes
      FROM etl.LoadWatermark AS w
     WHERE w.TargetObject = N'dw.FactTitleRating';

    IF @FullReload = 1 OR @LastMark IS NULL
        SET @From = '1900-01-01';
    ELSE
        SET @From = DATEADD(MINUTE, -ISNULL(@Lookback, 4320), @LastMark);

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadFactTitleRating', N'dw.FactTitleRating',
            CASE WHEN @From = '1900-01-01' THEN 'Full' ELSE 'Incremental' END);
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        TRUNCATE TABLE etl.StgReview;

        INSERT INTO etl.StgReview
        (
            ReviewID, ProfileID, SubscriberID, TitleID, PrimaryGenreID, CountryID,
            RatingValue, HelpfulVotes, HasTextFlag, IsFlaggedFlag, ReviewLength,
            CreatedAt, UpdatedAt, ReviewDate, ReviewDateKey, ReviewHour
        )
        SELECT
            r.ReviewID,
            r.ProfileID,
            p.SubscriberID,
            r.TitleID,
            pg.GenreID,
            sb.CountryID,
            r.RatingValue,
            r.HelpfulVotes,
            CASE WHEN LEN(LTRIM(RTRIM(ISNULL(r.ReviewText, N'')))) > 0 THEN 1 ELSE 0 END,
            CAST(r.IsFlagged AS TINYINT),
            ISNULL(LEN(r.ReviewText), 0),
            r.CreatedAt,
            r.UpdatedAt,
            CAST(r.CreatedAt AS DATE),
            CONVERT(INT, CONVERT(CHAR(8), CAST(r.CreatedAt AS DATE), 112)),
            DATEPART(HOUR, r.CreatedAt)
        FROM HBOMaxOLTP.play.Review AS r
        INNER JOIN HBOMaxOLTP.acct.Profile    AS p  ON p.ProfileID     = r.ProfileID
        INNER JOIN HBOMaxOLTP.acct.Subscriber AS sb ON sb.SubscriberID = p.SubscriberID
        OUTER APPLY
        (
            SELECT TOP (1) tg.GenreID
            FROM HBOMaxOLTP.cat.TitleGenre AS tg
            INNER JOIN HBOMaxOLTP.cat.Genre AS g ON g.GenreID = tg.GenreID
            WHERE tg.TitleID = r.TitleID
            ORDER BY tg.IsPrimaryGenre DESC, g.GenreName
        ) AS pg
        WHERE r.CreatedAt >= @From
           OR r.UpdatedAt >= @From;

        SELECT @RowsRead = COUNT(*),
               @NewMark  = MAX(CASE WHEN UpdatedAt > CreatedAt THEN UpdatedAt ELSE CreatedAt END)
          FROM etl.StgReview;

        IF @From = '1900-01-01'
            DELETE FROM dw.FactTitleRating;
        ELSE
            DELETE f
              FROM dw.FactTitleRating AS f
              INNER JOIN etl.StgReview AS s ON s.ReviewID = f.ReviewID;

        SET @RowsDel = @@ROWCOUNT;

        INSERT INTO dw.FactTitleRating
        (
            DateKey, TimeKey, TitleKey, GenreKey, ProfileKey, SubscriberKey, GeographyKey,
            ReviewID, CreatedAt, UpdatedAt, RatingValue, ReviewCount, HelpfulVotes,
            HasTextFlag, IsFlaggedFlag, ReviewLength, BatchID
        )
        SELECT
            ISNULL(dd.DateKey, -1),
            ISNULL(tod.TimeKey, -1),
            ISNULL(dt.TitleKey, -1),
            ISNULL(dg.GenreKey, -1),
            ISNULL(dp.ProfileKey, -1),
            ISNULL(dsv.SubscriberKey, -1),
            ISNULL(geo.GeographyKey, -1),
            s.ReviewID,
            s.CreatedAt,
            s.UpdatedAt,
            s.RatingValue,
            1,
            s.HelpfulVotes,
            s.HasTextFlag,
            s.IsFlaggedFlag,
            s.ReviewLength,
            @BatchID
        FROM etl.StgReview AS s
        LEFT JOIN dw.DimDate      AS dd  ON dd.DateKey   = s.ReviewDateKey
        LEFT JOIN dw.DimTimeOfDay AS tod ON tod.TimeKey  = s.ReviewHour
        LEFT JOIN dw.DimTitle     AS dt  ON dt.TitleID   = s.TitleID
        LEFT JOIN dw.DimGenre     AS dg  ON dg.GenreID   = s.PrimaryGenreID
        LEFT JOIN dw.DimProfile   AS dp  ON dp.ProfileID = s.ProfileID
        OUTER APPLY
        (
            SELECT TOP (1) d.SubscriberKey, d.CountryID
            FROM dw.DimSubscriber AS d
            WHERE d.SubscriberID = s.SubscriberID
              AND d.SubscriberKey <> -1
            ORDER BY CASE WHEN s.ReviewDate BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dsv
        LEFT JOIN dw.DimGeography AS geo ON geo.CountryID = ISNULL(dsv.CountryID, s.CountryID);

        SET @RowsIns = @@ROWCOUNT;

        SELECT @Unresolved = COUNT(*)
          FROM dw.FactTitleRating
         WHERE BatchID = @BatchID
           AND -1 IN (DateKey, TimeKey, TitleKey, GenreKey, ProfileKey, SubscriberKey,
                      GeographyKey);

        UPDATE etl.LoadWatermark
           SET LastLoadedDateTime = CASE WHEN @NewMark IS NULL THEN LastLoadedDateTime
                                         WHEN LastLoadedDateTime IS NULL OR @NewMark > LastLoadedDateTime
                                              OR @From = '1900-01-01' THEN @NewMark
                                         ELSE LastLoadedDateTime END,
               LastLoadAt         = SYSUTCDATETIME(),
               RowsLastLoad       = @RowsIns,
               RowUpdatedAt       = SYSUTCDATETIME()
         WHERE TargetObject = N'dw.FactTitleRating';

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns - CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsUpdated  = CASE WHEN @RowsDel > @RowsIns THEN @RowsIns ELSE @RowsDel END,
               RowsRejected = @Unresolved, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO


/* =============================================================================
   etl.usp_LoadFactSubscriptionMonthlySnapshot
   -----------------------------------------------------------------------------
   Target     : dw.FactSubscriptionMonthlySnapshot      Load type: Snapshot
   Source     : HBOMaxOLTP.acct.Subscription x the month-end rows of dw.DimDate
                (IsLastDayOfMonth = 1), up to and including the CURRENT month.
   Strategy   : full rebuild inside one transaction (delete all, insert all).
                Snapshot volume is subscriptions x months, which is small, and a
                rebuild means a late correction to a start/end date restates
                every affected month consistently.

   Which months a subscription appears in
     EffectiveEnd = EndDate, else CAST(CancelledAt AS DATE) for a Cancelled /
                    Expired subscription with no EndDate, else open (NULL).
     A month-end M is included when StartDate <= M (the subscription existed by
     the end of the month) AND the subscription had not ended before the month
     began (EffectiveEnd IS NULL OR EffectiveEnd >= first day of M's month).
     So the month in which a subscription ends is still present, flagged as the
     churn month, and nothing after it is.

   Snapshot attributes and measures
     SubscriptionStatus  The OLTP keeps only the CURRENT status, so the status AT
                         a past month-end is reconstructed:
                           ended on/before M        -> current status if it is a
                                                       terminal one (Cancelled /
                                                       Expired), else 'Expired'
                           TrialEndsOn >= M         -> 'Trialing'
                           M is the current month   -> current status
                           otherwise                -> 'Active'
     ActiveSubscriptionCount 1 when the subscription is still alive at M
                         (EffectiveEnd IS NULL OR EffectiveEnd > M), else 0.
     MonthlyRecurringRevenue for an alive, non-trialing, non-paused row: the
                         MonthlyPrice of the DimPlan version in force at M, or
                         AnnualPrice / 12 for an Annual billing cycle (falling
                         back to MonthlyPrice if the plan has no annual price).
                         0 otherwise.
     TenureMonths        whole months from StartDate to M (or to the end date).
     IsNewThisMonth      StartDate falls in M's month.
     IsChurnedThisMonth  EffectiveEnd falls in M's month.
     IsTrialing          status reconstructed as 'Trialing'.
     SignupDateKey /     the subscription StartDate - the cohort of a churn
     SignupCohortMonthKey  triangle is "the month this subscription started".
     Plan                etl.utvf_PlanInForce at M, then the DimPlan version at M.
     Subscriber/Geography the DimSubscriber version at M and its country.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadFactSubscriptionMonthlySnapshot;
GO

CREATE PROCEDURE etl.usp_LoadFactSubscriptionMonthlySnapshot
    @BatchID     UNIQUEIDENTIFIER = NULL,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @RowsDel INT = 0,
            @Unresolved INT = 0;
    DECLARE @CurrentMonthEnd DATE = EOMONTH(CAST(SYSUTCDATETIME() AS DATE));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadFactSubscriptionMonthlySnapshot',
            N'dw.FactSubscriptionMonthlySnapshot', 'Snapshot');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.acct.Subscription;

        DELETE FROM dw.FactSubscriptionMonthlySnapshot;
        SET @RowsDel = @@ROWCOUNT;

        WITH Sub AS
        (
            SELECT
                sub.SubscriptionID,
                sub.SubscriberID,
                sub.StartDate,
                sub.SubscriptionStatus,
                sub.BillingCycle,
                sub.AutoRenew,
                sub.TrialEndsOn,
                CASE WHEN sub.EndDate IS NOT NULL THEN sub.EndDate
                     WHEN sub.SubscriptionStatus IN ('Cancelled', 'Expired')
                          THEN CAST(sub.CancelledAt AS DATE)
                END AS EffectiveEnd
            FROM HBOMaxOLTP.acct.Subscription AS sub
        ),
        Grid AS
        (
            /* subscription x every month-end it was alive in */
            SELECT
                s.*,
                d.DateKey        AS SnapshotDateKey,
                d.FullDate       AS MonthEnd,
                d.MonthStartDate AS MonthStart,
                d.MonthKey       AS SnapshotMonthKey
            FROM Sub AS s
            INNER JOIN dw.DimDate AS d
                ON  d.IsLastDayOfMonth = 1
                AND d.DateKey <> -1
                AND d.FullDate >= s.StartDate
                AND d.FullDate <= @CurrentMonthEnd
                AND (s.EffectiveEnd IS NULL OR s.EffectiveEnd >= d.MonthStartDate)
        ),
        Shaped AS
        (
            SELECT
                g.*,
                CAST(CASE WHEN g.EffectiveEnd IS NOT NULL AND g.EffectiveEnd <= g.MonthEnd
                               THEN CASE WHEN g.SubscriptionStatus IN ('Cancelled', 'Expired')
                                         THEN g.SubscriptionStatus ELSE 'Expired' END
                          WHEN g.TrialEndsOn IS NOT NULL AND g.TrialEndsOn >= g.MonthEnd
                               THEN 'Trialing'
                          WHEN g.MonthEnd = @CurrentMonthEnd
                               THEN g.SubscriptionStatus
                          ELSE 'Active' END AS VARCHAR(12)) AS StatusAtMonthEnd,
                CAST(CASE WHEN g.EffectiveEnd IS NULL OR g.EffectiveEnd > g.MonthEnd
                          THEN 1 ELSE 0 END AS TINYINT)     AS IsAlive
            FROM Grid AS g
        )
        INSERT INTO dw.FactSubscriptionMonthlySnapshot
        (
            SnapshotDateKey, SubscriberKey, PlanKey, GeographyKey, SignupDateKey,
            SubscriptionID, SubscriptionStatus, BillingCycle, AutoRenew, SnapshotMonthKey,
            SignupCohortMonthKey, ActiveSubscriptionCount, MonthlyRecurringRevenue,
            TenureMonths, IsNewThisMonth, IsChurnedThisMonth, IsTrialing, BatchID
        )
        SELECT
            x.SnapshotDateKey,
            ISNULL(dsv.SubscriberKey, -1),
            ISNULL(dpl.PlanKey, -1),
            ISNULL(geo.GeographyKey, -1),
            ISNULL(dsd.DateKey, -1),
            x.SubscriptionID,
            x.StatusAtMonthEnd,
            x.BillingCycle,
            x.AutoRenew,
            x.SnapshotMonthKey,
            ISNULL(dsd.MonthKey, -1),
            x.IsAlive,
            CAST(CASE WHEN x.IsAlive = 0                                   THEN 0
                      WHEN x.StatusAtMonthEnd IN ('Trialing', 'Paused')    THEN 0
                      WHEN dpl.PlanKey IS NULL                             THEN 0
                      WHEN x.BillingCycle = 'Annual' AND dpl.AnnualPrice IS NOT NULL
                           THEN ROUND(dpl.AnnualPrice / 12.0, 2)
                      ELSE dpl.MonthlyPrice END AS DECIMAL(12,2)),
            DATEDIFF(MONTH, x.StartDate,
                     CASE WHEN x.EffectiveEnd IS NOT NULL AND x.EffectiveEnd < x.MonthEnd
                          THEN x.EffectiveEnd ELSE x.MonthEnd END),
            CASE WHEN x.StartDate >= x.MonthStart THEN 1 ELSE 0 END,
            CASE WHEN x.EffectiveEnd BETWEEN x.MonthStart AND x.MonthEnd THEN 1 ELSE 0 END,
            CASE WHEN x.StatusAtMonthEnd = 'Trialing' THEN 1 ELSE 0 END,
            @BatchID
        FROM Shaped AS x
        LEFT JOIN dw.DimDate AS dsd
            ON dsd.DateKey = CONVERT(INT, CONVERT(CHAR(8), x.StartDate, 112))
        OUTER APPLY etl.utvf_PlanInForce(x.SubscriptionID,
                                         CAST(x.MonthEnd AS DATETIME2(0))) AS pif
        OUTER APPLY
        (
            SELECT TOP (1) d.SubscriberKey, d.CountryID
            FROM dw.DimSubscriber AS d
            WHERE d.SubscriberID = x.SubscriberID
              AND d.SubscriberKey <> -1
            ORDER BY CASE WHEN x.MonthEnd BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dsv
        OUTER APPLY
        (
            SELECT TOP (1) d.PlanKey, d.MonthlyPrice, d.AnnualPrice
            FROM dw.DimPlan AS d
            WHERE d.PlanID = pif.PlanID
              AND d.PlanKey <> -1
            ORDER BY CASE WHEN x.MonthEnd BETWEEN d.RowEffectiveFrom AND d.RowEffectiveTo
                          THEN 0 ELSE 1 END,
                     d.RowEffectiveFrom
        ) AS dpl
        LEFT JOIN dw.DimGeography AS geo ON geo.CountryID = dsv.CountryID;

        SET @RowsIns = @@ROWCOUNT;

        SELECT @Unresolved = COUNT(*)
          FROM dw.FactSubscriptionMonthlySnapshot
         WHERE -1 IN (SnapshotDateKey, SubscriberKey, PlanKey, GeographyKey, SignupDateKey);

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns, RowsUpdated = 0,
               RowsRejected = @Unresolved, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO


/* =============================================================================
   etl.usp_LoadFactCatalogAvailabilitySnapshot
   -----------------------------------------------------------------------------
   Target     : dw.FactCatalogAvailabilitySnapshot      Load type: Snapshot
   Source     : HBOMaxOLTP.cat.TitleAvailability x the month-end rows of
                dw.DimDate, up to and including the current month.
   Strategy   : full rebuild (delete all, insert all) in one transaction.
   Inclusion  : month-end M is included when AvailableFrom <= M and
                (AvailableUntil IS NULL OR AvailableUntil >= M) - i.e. the
                licence window covered that month-end.
   Measures
     TitlesAvailableCount 1 per row (semi-additive: sum within one month only).
     DaysInCatalog        AvailableFrom -> M.
     DaysUntilExpiry      M -> AvailableUntil; NULL for an open-ended licence.
     IsExpiringSoon       1 when the licence ends within 90 days after M - the
                          renewal-negotiation horizon used on the report's
                          "Expiring Soon %" card. The threshold is a parameter.
   Keys       : GenreKey from the title's primary genre (same rule as DimTitle);
                AvailableUntilDateKey is -1 for an open-ended licence and for a
                date outside the generated calendar.
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_LoadFactCatalogAvailabilitySnapshot;
GO

CREATE PROCEDURE etl.usp_LoadFactCatalogAvailabilitySnapshot
    @BatchID           UNIQUEIDENTIFIER = NULL,
    @PackageName       SYSNAME          = N'HBOMaxDW_FullLoad',
    @ExpiringSoonDays  INT              = 90
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @RowsRead INT = 0, @RowsIns INT = 0, @Unresolved INT = 0;
    DECLARE @CurrentMonthEnd DATE = EOMONTH(CAST(SYSUTCDATETIME() AS DATE));

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_LoadFactCatalogAvailabilitySnapshot',
            N'dw.FactCatalogAvailabilitySnapshot', 'Snapshot');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @RowsRead = COUNT(*) FROM HBOMaxOLTP.cat.TitleAvailability;

        DELETE FROM dw.FactCatalogAvailabilitySnapshot;

        INSERT INTO dw.FactCatalogAvailabilitySnapshot
        (
            SnapshotDateKey, TitleKey, GenreKey, GeographyKey, AvailableFromDateKey,
            AvailableUntilDateKey, LicenseType, SnapshotMonthKey, TitlesAvailableCount,
            DaysInCatalog, DaysUntilExpiry, IsExpiringSoon, BatchID
        )
        SELECT
            d.DateKey,
            ISNULL(dt.TitleKey, -1),
            ISNULL(dg.GenreKey, -1),
            ISNULL(geo.GeographyKey, -1),
            ISNULL(dfrom.DateKey, -1),
            ISNULL(duntil.DateKey, -1),
            ta.LicenseType,
            d.MonthKey,
            1,
            DATEDIFF(DAY, ta.AvailableFrom, d.FullDate),
            CASE WHEN ta.AvailableUntil IS NOT NULL
                 THEN DATEDIFF(DAY, d.FullDate, ta.AvailableUntil) END,
            CASE WHEN ta.AvailableUntil IS NOT NULL
                  AND DATEDIFF(DAY, d.FullDate, ta.AvailableUntil) <= @ExpiringSoonDays
                 THEN 1 ELSE 0 END,
            @BatchID
        FROM HBOMaxOLTP.cat.TitleAvailability AS ta
        INNER JOIN dw.DimDate AS d
            ON  d.IsLastDayOfMonth = 1
            AND d.DateKey <> -1
            AND d.FullDate >= ta.AvailableFrom
            AND (ta.AvailableUntil IS NULL OR ta.AvailableUntil >= d.FullDate)
            AND d.FullDate <= @CurrentMonthEnd
        LEFT JOIN dw.DimTitle     AS dt     ON dt.TitleID    = ta.TitleID
        LEFT JOIN dw.DimGenre     AS dg     ON dg.GenreID    = dt.PrimaryGenreID
        LEFT JOIN dw.DimGeography AS geo    ON geo.CountryID = ta.CountryID
        LEFT JOIN dw.DimDate      AS dfrom
            ON dfrom.DateKey  = CONVERT(INT, CONVERT(CHAR(8), ta.AvailableFrom, 112))
        LEFT JOIN dw.DimDate      AS duntil
            ON duntil.DateKey = CONVERT(INT, CONVERT(CHAR(8), ta.AvailableUntil, 112));

        SET @RowsIns = @@ROWCOUNT;

        /* AvailableUntilDateKey = -1 is EXPECTED for open-ended licences, so it
           is not counted as an unresolved lookup. */
        SELECT @Unresolved = COUNT(*)
          FROM dw.FactCatalogAvailabilitySnapshot
         WHERE -1 IN (SnapshotDateKey, TitleKey, GenreKey, GeographyKey, AvailableFromDateKey);

        COMMIT TRANSACTION;

        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), RowsRead = @RowsRead,
               RowsInserted = @RowsIns, RowsUpdated = 0,
               RowsRejected = @Unresolved, LoadStatus = 'Succeeded'
         WHERE LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = ERROR_MESSAGE()
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO


/* =============================================================================
   etl.usp_RunFullLoad  -  the orchestrator
   -----------------------------------------------------------------------------
   Runs every load procedure in dependency order under ONE BatchID, so a whole
   run can be inspected with
       SELECT * FROM etl.LoadAudit WHERE BatchID = @BatchID ORDER BY LoadAuditID;

   Order
     1. Generated dimensions : DimDate, DimTimeOfDay
     2. Reference dimensions : DimGeography, DimGenre
     3. SCD Type 2           : DimPlan, DimSubscriber
     4. Type 1               : DimProfile, DimTitle, DimDevice, DimPaymentMethod
     5. Transaction facts    : FactViewingSession, FactRevenue, FactTitleRating
     6. Snapshot facts       : FactSubscriptionMonthlySnapshot,
                               FactCatalogAvailabilitySnapshot
   Every dimension must be loaded before any fact, because the facts resolve
   their surrogate keys against them.

   Failure handling
     Each step commits on its own (each procedure owns its transaction), so a
     failure in step N leaves steps 1..N-1 committed and consistent - the
     warehouse is never half-loaded INSIDE a table. The orchestrator stops at the
     first failure, marks its own audit row Failed with the failing procedure's
     error, and re-throws. Because every procedure is idempotent, the fix is
     simply to run etl.usp_RunFullLoad again.

   Parameters
     @FullReload = 1 makes the three incremental facts ignore their watermarks
     and rebuild from the whole source (the snapshots always rebuild).
   ============================================================================= */
DROP PROCEDURE IF EXISTS etl.usp_RunFullLoad;
GO

CREATE PROCEDURE etl.usp_RunFullLoad
    @FullReload  BIT              = 0,
    @PackageName SYSNAME          = N'HBOMaxDW_FullLoad',
    @BatchID     UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AuditID BIGINT, @Step SYSNAME;

    SET @BatchID = ISNULL(@BatchID, NEWID());

    INSERT INTO etl.LoadAudit (BatchID, PackageName, ProcedureName, TargetObject, LoadType)
    VALUES (@BatchID, @PackageName, N'etl.usp_RunFullLoad', N'HBOMaxDW', 'Orchestrator');
    SET @AuditID = SCOPE_IDENTITY();

    BEGIN TRY
        SET @Step = N'etl.usp_LoadDimDate';
        EXEC etl.usp_LoadDimDate         @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimTimeOfDay';
        EXEC etl.usp_LoadDimTimeOfDay    @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimGeography';
        EXEC etl.usp_LoadDimGeography    @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimGenre';
        EXEC etl.usp_LoadDimGenre        @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimPlan';
        EXEC etl.usp_LoadDimPlan         @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimSubscriber';
        EXEC etl.usp_LoadDimSubscriber   @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimProfile';
        EXEC etl.usp_LoadDimProfile      @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimTitle';
        EXEC etl.usp_LoadDimTitle        @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimDevice';
        EXEC etl.usp_LoadDimDevice       @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadDimPaymentMethod';
        EXEC etl.usp_LoadDimPaymentMethod @BatchID = @BatchID, @PackageName = @PackageName;

        SET @Step = N'etl.usp_LoadFactViewingSession';
        EXEC etl.usp_LoadFactViewingSession @BatchID = @BatchID, @PackageName = @PackageName,
                                            @FullReload = @FullReload;
        SET @Step = N'etl.usp_LoadFactRevenue';
        EXEC etl.usp_LoadFactRevenue        @BatchID = @BatchID, @PackageName = @PackageName,
                                            @FullReload = @FullReload;
        SET @Step = N'etl.usp_LoadFactTitleRating';
        EXEC etl.usp_LoadFactTitleRating    @BatchID = @BatchID, @PackageName = @PackageName,
                                            @FullReload = @FullReload;

        SET @Step = N'etl.usp_LoadFactSubscriptionMonthlySnapshot';
        EXEC etl.usp_LoadFactSubscriptionMonthlySnapshot @BatchID = @BatchID, @PackageName = @PackageName;
        SET @Step = N'etl.usp_LoadFactCatalogAvailabilitySnapshot';
        EXEC etl.usp_LoadFactCatalogAvailabilitySnapshot @BatchID = @BatchID, @PackageName = @PackageName;

        UPDATE a
           SET CompletedAt  = SYSUTCDATETIME(),
               RowsRead     = x.RowsRead,
               RowsInserted = x.RowsInserted,
               RowsUpdated  = x.RowsUpdated,
               RowsRejected = x.RowsRejected,
               LoadStatus   = 'Succeeded'
          FROM etl.LoadAudit AS a
          CROSS APPLY
          (
              SELECT ISNULL(SUM(c.RowsRead), 0)     AS RowsRead,
                     ISNULL(SUM(c.RowsInserted), 0) AS RowsInserted,
                     ISNULL(SUM(c.RowsUpdated), 0)  AS RowsUpdated,
                     ISNULL(SUM(c.RowsRejected), 0) AS RowsRejected
              FROM etl.LoadAudit AS c
              WHERE c.BatchID = @BatchID
                AND c.LoadAuditID <> @AuditID
          ) AS x
         WHERE a.LoadAuditID = @AuditID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE etl.LoadAudit
           SET CompletedAt = SYSUTCDATETIME(), LoadStatus = 'Failed',
               ErrorNumber = ERROR_NUMBER(), ErrorLine = ERROR_LINE(),
               ErrorMessage = LEFT(N'Step ' + ISNULL(@Step, N'?') + N': ' + ERROR_MESSAGE(), 2048)
         WHERE LoadAuditID = @AuditID;
        THROW;
    END CATCH
END
GO

PRINT '14_etl_procedures.sql - part 4 of 4 loaded (5 fact loads, etl.utvf_PlanInForce, etl.usp_RunFullLoad).';
GO
