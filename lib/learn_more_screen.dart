// lib/learn_more_screen.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

class LearnMoreScreen extends StatefulWidget {
  const LearnMoreScreen({Key? key}) : super(key: key);

  @override
  State<LearnMoreScreen> createState() => _LearnMoreScreenState();
}

class _FaqItem {
  final String question;
  final Widget answer;
  _FaqItem(this.question, this.answer);
}

class _LearnMoreScreenState extends State<LearnMoreScreen> {
  late final List<_FaqItem> _items;

  @override
  void initState() {
    super.initState();
    _items = [
      _FaqItem(
        'What Is COVID-19?',
        const Text(
          'COVID-19 is a respiratory illness caused by the SARS-CoV-2 virus. '
          'It first appeared in late 2019 and quickly spread globally. '
          'While many people only get mild symptoms, it can also lead to serious illness.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Why It Matters',
        const Text(
          '• Over 600 million cases worldwide\n'
          '• Millions of hospitalizations and deaths',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'How It Spreads',
        const Text(
          '• Droplets: coughs, sneezes & talking\n'
          '• Airborne: tiny particles in poorly ventilated spaces\n'
          '• Close contact: within about 6 feet of someone\n'
          '• Surfaces: possible but much less common',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Common Symptoms',
        const Text(
          'Fever or chills, cough, shortness of breath, loss of taste or smell, '
          'fatigue, muscle aches, headache, sore throat, congestion',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Prevention Tips',
        const Text(
          '• Wear a mask in shared indoor spaces\n'
          '• Wash hands for at least 20 seconds\n'
          '• Keep 6 feet distance from others\n'
          '• Ventilate rooms by opening windows or using filters\n'
          '• Stay home if you feel sick or test positive',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Testing & Diagnosis',
        const Text(
          'PCR tests give lab-confirmed results in 1–3 days. '
          'Rapid antigen tests give results in 15–30 minutes (best when you have symptoms). '
          'Test if you feel sick, after exposure, or before seeing high-risk individuals.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Treatment & Care',
        const Text(
          'At home: rest, fluids, over-the-counter fever reducers (ibuprofen, acetaminophen). '
          'Seek medical help if you have trouble breathing, chest pain, or confusion. '
          'High-risk folks may qualify for antivirals or monoclonal antibody therapy.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Vaccines & Boosters',
        const Text(
          'Vaccines reduce your risk of severe illness, hospitalization, and death. '
          'Find a shot near you via your local health department or pharmacy. '
          'Mild soreness or fever afterward is normal.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
      _FaqItem(
        'Multimedia & Resources',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLink('WHO COVID-19 page', 'https://www.who.int/emergencies/diseases/novel-coronavirus-2019'),
            const SizedBox(height: 4),
            _buildLink('CDC COVID-19 page', 'https://www.cdc.gov/coronavirus/2019-ncov/index.html'),
            const SizedBox(height: 4),
            _buildLink('Find a Vaccine', 'https://www.vaccines.gov/'),
          ],
        ),
      ),
      _FaqItem(
        'FAQ',
        const Text(
          '1. How long am I contagious?\n'
          '   Typically 1–2 days before symptoms and up to 10 days after.\n\n'
          '2. Can I get COVID more than once?\n'
          '   Yes. Immunity fades and new variants can bypass it.\n\n'
          '3. Do I still need a booster if I had COVID?\n'
          '   Yes. A booster gives stronger, longer-lasting protection.',
          style: TextStyle(fontSize: 16, height: 1.5),
        ),
      ),
    ];
  }

  static Widget _buildLink(String label, String url) {
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      },
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 16,
          color: CupertinoColors.activeBlue,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Learn More'),
      ),
      child: SafeArea(
        child: Material(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          child: SingleChildScrollView(
            child: Localizations(
              locale: const Locale('en', ''),
              delegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              child: ExpansionPanelList.radio(
                children: _items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  return ExpansionPanelRadio(
                    value: index,
                    headerBuilder: (context, isExpanded) => ListTile(
                      title: Text(
                        item.question,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                    body: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: item.answer,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
