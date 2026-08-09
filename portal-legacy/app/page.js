"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { registerInterest } from "../lib/gateway";

export default function Home() {
  const router = useRouter();
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <>
      <nav className={`nav${scrolled ? " scrolled" : ""}`}>
        <div className="wrap nav-inner">
          <a className="wordmark" href="#top">
            <span className="wordmark-mark" aria-hidden="true" />
            CogniHire
          </a>
          <div className="nav-links">
            <a className="nav-hide-sm" href="#how">How it works</a>
            <a className="nav-hide-sm" href="#difference">What&rsquo;s different</a>
            <a className="nav-hide-sm" href="#register">Register</a>
            <button
              className="btn btn-secondary btn-sm"
              onClick={() => router.push("/interview")}
            >
              I have a code
            </button>
          </div>
        </div>
      </nav>

      <main id="top">
        <section className="hero">
          <div className="wrap">
            <p className="eyebrow">Verified-claim interviewing</p>
            <h1>Interviews that check the claim, not the candidate.</h1>
            <p className="lede">
              A résumé is a list of claims. Most interviews never get around to
              testing them. CogniHire reads the résumé, finds the specific
              claims in it, and runs an interview built entirely around asking
              the candidate to substantiate those claims in their own words.
            </p>
            <div className="hero-actions">
              <a className="btn btn-primary" href="#register">
                Register a session
              </a>
              <a className="btn btn-secondary" href="#how">
                See how it works
              </a>
            </div>
            <p className="hero-note">
              No score. No ranking. No black box — every conclusion cites the
              candidate&rsquo;s own answer.
            </p>
          </div>
        </section>

        <section className="band" id="problem">
          <div className="wrap">
            <p className="eyebrow">The problem</p>
            <h2>&ldquo;Led a team of four engineers.&rdquo; Did they?</h2>
            <p className="lede" style={{ marginTop: 20 }}>
              Screening tools have gotten very good at ranking résumés and very
              bad at checking whether what&rsquo;s written on them is true. They
              output a number nobody can trace back to anything the candidate
              actually said — which is exactly the part a hiring decision needs
              to be defensible.
            </p>

            <div className="grid grid-3">
              <div className="card">
                <h3>Keyword matching isn&rsquo;t verification</h3>
                <p>
                  Matching &ldquo;PostgreSQL&rdquo; in a résumé against
                  &ldquo;PostgreSQL&rdquo; in a job description tells you the
                  word appears twice. It says nothing about whether the person
                  can do the work.
                </p>
              </div>
              <div className="card">
                <h3>A score you can&rsquo;t explain</h3>
                <p>
                  An 82/100 with no derivation is not evidence. If a candidate
                  asks why they were rejected, or a regulator does, a number
                  isn&rsquo;t an answer.
                </p>
              </div>
              <div className="card">
                <h3>Unstructured interviews drift</h3>
                <p>
                  Two interviewers, two different conversations, two different
                  standards. The claims that get probed depend on who happened
                  to be in the room.
                </p>
              </div>
            </div>
          </div>
        </section>

        <section id="how">
          <div className="wrap">
            <p className="eyebrow">How it works</p>
            <h2>From résumé to evidence, in five steps.</h2>

            <div className="steps">
              <div className="step">
                <span className="step-num" aria-hidden="true" />
                <div>
                  <h3>The résumé is read, not scanned</h3>
                  <p>
                    Text is extracted from the PDF and turned into a structured
                    profile: skills, projects, experience, education — kept
                    separate from anything inferred about them.
                  </p>
                </div>
              </div>
              <div className="step">
                <span className="step-num" aria-hidden="true" />
                <div>
                  <h3>Claims are extracted and grounded</h3>
                  <p>
                    Each claim must appear verbatim in the source document to
                    survive. Anything the model invents, embellishes, or infers
                    is discarded before it can reach an interviewer.
                  </p>
                </div>
              </div>
              <div className="step">
                <span className="step-num" aria-hidden="true" />
                <div>
                  <h3>Questions are planned against those claims</h3>
                  <p>
                    Every question exists to test a specific claim. A topic with
                    no claim behind it doesn&rsquo;t get asked — there would be
                    nothing to substantiate.
                  </p>
                </div>
              </div>
              <div className="step">
                <span className="step-num" aria-hidden="true" />
                <div>
                  <h3>The interview adapts as it goes</h3>
                  <p>
                    A vague answer gets a follow-up. A substantiated one moves
                    on. The interview tracks which claims are covered and which
                    still need evidence.
                  </p>
                </div>
              </div>
              <div className="step">
                <span className="step-num" aria-hidden="true" />
                <div>
                  <h3>Evidence is linked back to each claim</h3>
                  <p>
                    The report is one row per claim: the question asked, the
                    candidate&rsquo;s own words as the evidence quote, and
                    whether it held up. Nothing is asserted without a citation.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="band" id="difference">
          <div className="wrap">
            <p className="eyebrow">What&rsquo;s different</p>
            <h2>We tell you what we couldn&rsquo;t check.</h2>
            <p className="lede" style={{ marginTop: 20 }}>
              The easiest way to look accurate is to never admit a gap.
              CogniHire does the opposite: an unverified claim is reported as
              unverified, and a stage that had to fall back to a simpler method
              says so on the record.
            </p>

            <div className="grid grid-2" style={{ alignItems: "start" }}>
              <div className="proof" role="img" aria-label="Example report: one claim substantiated, one not reached">
                <p className="meta" style={{ marginBottom: 14 }}>
                  Example report extract
                </p>
                <div className="proof-row">
                  <span className="tag tag-verified">Substantiated</span>
                  <div>
                    <div className="proof-claim">
                      &ldquo;Led a team of 4 engineers on a payments
                      migration.&rdquo;
                    </div>
                    <div className="proof-quote">
                      &ldquo;I ran the migration planning, split the cutover into
                      three phases, and owned the rollback plan…&rdquo;
                    </div>
                  </div>
                </div>
                <div className="proof-row">
                  <span className="tag tag-unmeasured">Not substantiated</span>
                  <div>
                    <div className="proof-claim">
                      &ldquo;Cut p95 latency by 60%.&rdquo;
                    </div>
                    <div className="proof-quote">
                      Asked twice; the candidate described the index change but
                      not how the figure was measured.
                    </div>
                  </div>
                </div>
              </div>

              <div style={{ display: "grid", gap: 20 }}>
                <div className="card">
                  <h3>No score, by design</h3>
                  <p>
                    CogniHire never outputs a number that ranks one person
                    against another. It reports which claims held up and which
                    didn&rsquo;t, and leaves the judgement to the human who is
                    accountable for it.
                  </p>
                </div>
                <div className="card">
                  <h3>Grounded, or discarded</h3>
                  <p>
                    A deterministic gate sits between the model and the record.
                    Claim text that isn&rsquo;t present in the source document
                    doesn&rsquo;t make it through, so a model&rsquo;s guess can
                    never acquire the authority of something the candidate said.
                  </p>
                </div>
                <div className="card">
                  <h3>Honest about degradation</h3>
                  <p>
                    If the language model is unavailable, the system falls back
                    to a simpler method and labels the output accordingly rather
                    than quietly producing something weaker that looks
                    identical.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="register">
          <div className="wrap">
            <RegisterCard />
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="wrap footer-inner">
          <span>© {new Date().getFullYear()} CogniHire</span>
          <span>
            Have an interview code?{" "}
            <a href="/interview" style={{ color: "var(--gold-action)" }}>
              Start your interview
            </a>
          </span>
        </div>
      </footer>
    </>
  );
}

function RegisterCard() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState("idle"); // idle | sending | sent | error
  const [message, setMessage] = useState("");

  async function submit(e) {
    e.preventDefault();
    const trimmed = email.trim();
    if (!trimmed) return;

    setState("sending");
    setMessage("");
    try {
      const result = await registerInterest(trimmed);
      setState("sent");
      setMessage(
        result?.message ||
          `We've sent a registration link to ${trimmed}. Check your inbox — and your spam folder, just in case.`
      );
    } catch (error) {
      setState("error");
      setMessage(
        error?.message ||
          "We couldn't send that just now. Please try again in a moment."
      );
    }
  }

  return (
    <div className="register">
      <p className="eyebrow">Register a session</p>
      <h2>Get your registration link by email.</h2>
      <p className="lede">
        Enter your email and we&rsquo;ll send you the registration form. Fill it
        in with your details and résumé, and we&rsquo;ll follow up with your
        interview code and a time.
      </p>

      {state === "sent" ? (
        <div className="notice notice-ok" role="status">
          {message}
        </div>
      ) : (
        <form onSubmit={submit}>
          <div className="field-row">
            <input
              className="input"
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
              aria-label="Your email address"
              disabled={state === "sending"}
            />
            <button
              className="btn btn-primary"
              type="submit"
              disabled={state === "sending"}
            >
              {state === "sending" ? (
                <>
                  <span className="spin" aria-hidden="true" />
                  Sending…
                </>
              ) : (
                "Send me the link"
              )}
            </button>
          </div>

          {state === "error" && (
            <div className="notice notice-error" role="alert">
              {message}
            </div>
          )}

          <p className="form-note">
            We use your email only to send this registration link.
          </p>
        </form>
      )}
    </div>
  );
}
