/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    03_indexes.sql
   Purpose: Non-clustered indexes on OLTP foreign keys and common search paths.
   Target:  Microsoft SQL Server 2019+
   Depends: 02_tables.sql must have run first.

   SQL Server creates an index automatically for every PRIMARY KEY and UNIQUE
   constraint, but it does NOT create one for each FOREIGN KEY. The indexes
   below exist to make the ETL and the day-to-day OLTP queries efficient:
     - every FK column is covered so joins and cascading deletes seek rather
       than scan,
     - a handful of filtered indexes support "current/active" lookups,
     - a few include-covered indexes support the hottest reporting queries.
   ============================================================================= */

USE HBOMaxOLTP;
GO

/* ----- cat ---------------------------------------------------------------- */
CREATE INDEX IX_Person_BirthCountry        ON cat.Person        (BirthCountryID);
CREATE INDEX IX_Studio_Country             ON cat.Studio        (HeadquartersCountryID);
CREATE INDEX IX_Title_Language             ON cat.Title         (OriginalLanguageID);
CREATE INDEX IX_Title_Studio               ON cat.Title         (StudioID);
CREATE INDEX IX_Title_Type_InCatalog       ON cat.Title         (TitleType) WHERE RemovedFromCatalogAt IS NULL;
CREATE INDEX IX_Season_Title               ON cat.Season        (TitleID);
CREATE INDEX IX_Episode_Season             ON cat.Episode       (SeasonID);
CREATE INDEX IX_TitleGenre_Genre           ON cat.TitleGenre    (GenreID);
CREATE INDEX IX_Credit_Person              ON cat.Credit        (PersonID);
CREATE INDEX IX_TLT_Language               ON cat.TitleLanguageTrack (LanguageID);
CREATE INDEX IX_TitleAvail_Country         ON cat.TitleAvailability  (CountryID);
GO

/* ----- acct --------------------------------------------------------------- */
CREATE INDEX IX_Subscriber_Country         ON acct.Subscriber   (CountryID);
CREATE INDEX IX_Subscriber_Language        ON acct.Subscriber   (PreferredLanguageID);
CREATE INDEX IX_Subscriber_Status          ON acct.Subscriber   (AccountStatus) INCLUDE (RegisteredAt);
CREATE INDEX IX_Sub_Subscriber             ON acct.Subscription (SubscriberID);
CREATE INDEX IX_Sub_Plan                   ON acct.Subscription (PlanID);
CREATE INDEX IX_Sub_Status_ActiveOnly      ON acct.Subscription (SubscriptionStatus, PlanID) WHERE EndDate IS NULL;
CREATE INDEX IX_SubChg_Sub                 ON acct.SubscriptionChangeLog (SubscriptionID, ChangedAt);
CREATE INDEX IX_SubChg_OldPlan             ON acct.SubscriptionChangeLog (OldPlanID);
CREATE INDEX IX_SubChg_NewPlan             ON acct.SubscriptionChangeLog (NewPlanID);
CREATE INDEX IX_Profile_Subscriber         ON acct.Profile      (SubscriberID);
CREATE INDEX IX_Profile_Language           ON acct.Profile      (PreferredLanguageID);
CREATE INDEX IX_Device_Subscriber          ON acct.Device       (SubscriberID);
GO

/* ----- play --------------------------------------------------------------- */
CREATE INDEX IX_WS_Profile                 ON play.WatchSession (ProfileID,  StartedAt);
CREATE INDEX IX_WS_Title                   ON play.WatchSession (TitleID,    StartedAt);
CREATE INDEX IX_WS_Episode                 ON play.WatchSession (EpisodeID);
CREATE INDEX IX_WS_Device                  ON play.WatchSession (DeviceID);
CREATE INDEX IX_WS_Country                 ON play.WatchSession (CountryID);
CREATE INDEX IX_WS_StartedAt               ON play.WatchSession (StartedAt) INCLUDE (SecondsWatched, IsCompleted);
CREATE INDEX IX_Watchlist_Title            ON play.Watchlist    (TitleID);
CREATE INDEX IX_Review_Title               ON play.Review       (TitleID);
CREATE INDEX IX_Review_CreatedAt           ON play.Review       (CreatedAt) INCLUDE (RatingValue);
CREATE INDEX IX_Download_Profile           ON play.Download     (ProfileID);
CREATE INDEX IX_Download_Device            ON play.Download     (DeviceID);
CREATE INDEX IX_Download_Title             ON play.Download     (TitleID);
CREATE INDEX IX_Download_Episode           ON play.Download     (EpisodeID);
GO

/* ----- bill --------------------------------------------------------------- */
CREATE INDEX IX_PM_Subscriber              ON bill.PaymentMethod (SubscriberID);
CREATE INDEX IX_PM_Country                 ON bill.PaymentMethod (BillingCountryID);
CREATE INDEX IX_Invoice_Sub                ON bill.Invoice       (SubscriptionID, IssuedDate);
CREATE INDEX IX_Invoice_Status             ON bill.Invoice       (InvoiceStatus) INCLUDE (TotalAmount);
CREATE INDEX IX_Invoice_IssuedDate         ON bill.Invoice       (IssuedDate);
CREATE INDEX IX_Payment_Invoice            ON bill.Payment       (InvoiceID);
CREATE INDEX IX_Payment_Method             ON bill.Payment       (PaymentMethodID);
CREATE INDEX IX_Payment_PaidAt             ON bill.Payment       (PaidAt) INCLUDE (Amount, PaymentStatus);
CREATE INDEX IX_SubCoupon_Coupon           ON bill.SubscriptionCoupon (CouponID);
GO

PRINT 'HBOMaxOLTP: indexes created.';
GO
