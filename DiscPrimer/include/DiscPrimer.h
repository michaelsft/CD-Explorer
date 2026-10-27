#ifndef DISC_PRIMER_H
#define DISC_PRIMER_H

// Some optical drives cannot read audio stored before Track 1 (a hidden
// track in Track 1's pre-gap) until they have been asked about Track 1.
// macOS reads exactly that area while probing an Enhanced CD's data session,
// so such discs can take minutes to appear. Asking the drive about Track 1 as
// soon as a disc arrives lets them appear in seconds. The request uses the
// shared MMC interface and never takes exclusive access to the drive.

// Starts watching for inserted discs and asks each disc's drive about Track 1,
// including discs already in a drive when watching starts.
void DiscPrimerStartWatching(void);

// 0: no disc inserted; 1: a disc is inserted but macOS is still examining it;
// 2: a disc is inserted and macOS has finished examining it.
int DiscPrimerInsertedDiscState(void);

// Identifies the inserted disc by its table of contents, read from macOS
// without accessing the drive. Returns 0 when no disc is published.
unsigned long long DiscPrimerInsertedDiscIdentity(void);

// Asks every drive holding a disc about Track 1, waiting for the answers.
// Returns the number of drives that answered.
int DiscPrimerPrimeInsertedDiscs(void);

#endif
