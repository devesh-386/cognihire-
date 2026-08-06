"""Ticket 19's fixed demo dataset — one organization, three roles, five
candidates spanning deliberately different resume qualities.

Every resume is formatted with `Skills` / `Experience` / `Education` as
standalone heading lines, matching the shape the heuristic (no-API-key)
fallback parser looks for — see `test_end_to_end.py`'s `RESUME_TEXT` for the
same convention. The point of a demo run in this sandbox is to show the
pipeline working in degraded mode; a real `OPENAI_API_KEY` (Ticket 15) reads
the same text more richly, not differently in kind.
"""

from __future__ import annotations

DEMO_ORG_NAME = "CogniHire Demo Co"

DEMO_ROLES = [
    {
        "title": "Backend Engineer",
        "required_skills": ["Python", "PostgreSQL", "Docker"],
        "desirable_skills": ["React"],
        "notes": "Demo role — backend focus.",
    },
    {
        "title": "Machine Learning Engineer",
        "required_skills": ["Python", "PyTorch", "TensorFlow"],
        "desirable_skills": ["Research"],
        "notes": "Demo role — ML focus.",
    },
    {
        "title": "Software Engineer (New Grad)",
        "required_skills": ["Python", "Java"],
        "desirable_skills": [],
        "notes": "Demo role — entry level.",
    },
]

DEMO_CANDIDATES = [
    {
        "name": "Priya Sharma",
        "email": "priya.sharma@demo.cognihire.test",
        "role_title": "Backend Engineer",
        "resume_text": """Priya Sharma
Senior Backend Engineer

Skills
Python, PostgreSQL, Docker, AWS, React

Experience
Completed a backend engineering internship at Vector Systems, shipping two production services.
Led a team of 4 engineers delivering a payments platform migration to PostgreSQL.
Built and deployed a React dashboard used by 300+ internal staff.
Designed a multi-tenant PostgreSQL schema handling 12M rows in production.

Certifications
AWS Certified Solutions Architect - Associate.
PostgreSQL Professional Certification.

Education
BSc Computer Science, Indian Institute of Technology.
""",
    },
    {
        "name": "Rahul Mehta",
        "email": "rahul.mehta@demo.cognihire.test",
        "role_title": "Backend Engineer",
        "resume_text": """Rahul Mehta
Backend Developer

Skills
Python, PostgreSQL, Docker

Experience
Worked on a small internal tool used by the finance team.
Fixed bugs and added minor features to an existing Django application.

Education
BSc Information Technology, Pune University.
""",
    },
    {
        "name": "Ananya Iyer",
        "email": "ananya.iyer@demo.cognihire.test",
        "role_title": "Software Engineer (New Grad)",
        "resume_text": """Ananya Iyer
Aspiring Software Engineer

Skills
Python, Java, Data Structures, Algorithms

Experience
Completed coursework projects in data structures and algorithms.
Built a personal to-do list web app as a class assignment.

Education
BSc Computer Science, University of Mumbai, graduating this year.
""",
    },
    {
        "name": "Wei Zhang",
        "email": "wei.zhang@demo.cognihire.test",
        "role_title": "Machine Learning Engineer",
        "resume_text": """Wei Zhang
Machine Learning Engineer

Skills
Python, PyTorch, TensorFlow, Research, NLP

Experience
Published a research paper on transformer efficiency at a peer-reviewed workshop.
Built and trained a PyTorch model for text classification deployed to production.
Ran large-scale TensorFlow training experiments across a multi-GPU cluster.
Mentored two junior researchers on experiment design.

Education
MSc Machine Learning, National University of Singapore.
""",
    },
    {
        "name": "Carlos Diaz",
        "email": "carlos.diaz@demo.cognihire.test",
        "role_title": "Backend Engineer",
        "resume_text": """Carlos Diaz
Backend Developer

Skills
Java, Spring Boot, Docker, PostgreSQL

Experience
Built and maintained a Spring Boot microservice handling 1M+ requests per day.
Containerized a legacy monolith into Docker services for a mid-sized fintech.
Wrote integration tests covering the core payments API.

Education
BSc Software Engineering, Universidad Nacional.
""",
    },
]
